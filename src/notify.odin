package shoji

// User notifications
// ------------------------------------------------------------------------
// Shoji runs as a background agent, so failures are posted through the
// Notification Center like any other app. Posting is opt-in by macOS: the
// first use asks for permission. Without an app bundle, permission, or the
// framework, messages stay in the log only. Admission is bounded: identical
// messages are suppressed for NOTIFY_DEDUPE_WINDOW and at most
// NOTIFY_RATE_LIMIT messages are posted per NOTIFY_RATE_WINDOW.

import "base:intrinsics"
import "core:fmt"
import "core:hash"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import objc "core:sys/darwin/Foundation"
import health "health"

NOTIFY_RATE_LIMIT :: 5
NOTIFY_RATE_WINDOW :: 10 * time.Minute
NOTIFY_DEDUPE_SLOTS :: 16
NOTIFY_DEDUPE_WINDOW :: time.Hour
NOTIFY_TEXT_LIMIT :: 400
USER_NOTIFICATIONS_PATH ::
	"/System/Library/Frameworks/UserNotifications.framework/UserNotifications"
// UNAuthorizationOptionSound | UNAuthorizationOptionAlert.
UN_AUTHORIZATION_SOUND_ALERT :: 2 | 4

Notify_Authorization :: enum i32 {
	Unknown,
	Granted,
	Denied,
}

Notify_Key :: struct {
	key: u64,
	at: time.Time,
}

Notifier :: struct {
	available: bool, // App bundle and framework present.
	authorization: Notify_Authorization, // Written by the framework callback.
	center: ^objc.Object,
	authorization_block: ^objc.Block,
	sent: [NOTIFY_RATE_LIMIT]time.Time,
	sent_count: int,
	recent: [NOTIFY_DEDUPE_SLOTS]Notify_Key,
	recent_next: int,
	suppressed: int, // Messages kept out of Notification Center by the bounds.
	sequence: u64,
}

@(default_calling_convention = "c")
foreign {
	objc_lookUpClass :: proc(name: cstring) -> rawptr ---
}

notify_key :: proc(title, body: string) -> u64 {
	return hash.fnv64a(transmute([]u8)title) ~ hash.fnv64a(transmute([]u8)body)
}

// Pure admission policy, separate from native posting for tests.
notifier_admit :: proc(n: ^Notifier, key: u64, now: time.Time) -> bool {
	for entry in n.recent {
		if entry.key == key && time.diff(entry.at, now) < NOTIFY_DEDUPE_WINDOW {
			n.suppressed += 1
			return false
		}
	}
	oldest := 0
	in_window := 0
	for i in 0 ..< n.sent_count {
		if time.diff(n.sent[i], now) < NOTIFY_RATE_WINDOW {in_window += 1}
		if time.diff(n.sent[i], n.sent[oldest]) > 0 {oldest = i}
	}
	if in_window >= NOTIFY_RATE_LIMIT {
		n.suppressed += 1
		return false
	}
	if n.sent_count < NOTIFY_RATE_LIMIT {
		n.sent[n.sent_count] = now
		n.sent_count += 1
	} else {
		n.sent[oldest] = now
	}
	n.recent[n.recent_next] = {key, now}
	n.recent_next = (n.recent_next + 1) % NOTIFY_DEDUPE_SLOTS
	return true
}

notify_authorization_result :: proc "c" (user: rawptr, granted: bool) {
	value := granted ? Notify_Authorization.Granted : Notify_Authorization.Denied
	sync.atomic_store((^Notify_Authorization)(user), value)
}

// Requests permission once. Only an app bundle has a notification identity;
// the framework raises an exception for a bare executable, so check first.
notifier_start :: proc(n: ^Notifier) {
	bundle := objc.Bundle_mainBundle()
	if bundle == nil || bundle->bundleIdentifier() == nil {
		return
	}
	path := bundle->bundlePath()
	if path == nil || !strings.has_suffix(string(path->UTF8String()), ".app") {
		return
	}
	if posix.dlopen(USER_NOTIFICATIONS_PATH, {.LAZY}) == nil {
		return
	}
	class := objc_lookUpClass("UNUserNotificationCenter")
	if class == nil {
		return
	}
	center := intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(class),
		"currentNotificationCenter",
	)
	if center == nil {
		return
	}
	n.center = center
	n.authorization_block = objc.Block_createGlobalWithParam(
		&n.authorization,
		notify_authorization_result,
	)
	intrinsics.objc_send(
		nil,
		center,
		"requestAuthorizationWithOptions:completionHandler:",
		uint(UN_AUTHORIZATION_SOUND_ALERT),
		n.authorization_block,
	)
	n.available = true
}

notifier_stop :: proc(n: ^Notifier) {
	// The center may still invoke the authorization block; it is global and
	// points into the notifier, which lives for the daemon's lifetime.
	n.available = false
	n.center = nil
}

notify_string :: proc(text: string) -> ^objc.String {
	clipped := text[:min(len(text), NOTIFY_TEXT_LIMIT)]
	text_object := objc.String_alloc()->initWithOdinString(clipped)
	text_object->autorelease()
	return text_object
}

// Logs the message and, when admitted and permitted, posts it.
notify :: proc(n: ^Notifier, title, body: string, now: time.Time) {
	fmt.eprintf("shoji: %s: %s\n", title, body)
	if !n.available || sync.atomic_load(&n.authorization) == .Denied {
		return
	}
	if !notifier_admit(n, notify_key(title, body), now) {
		return
	}
	content_class := objc_lookUpClass("UNMutableNotificationContent")
	request_class := objc_lookUpClass("UNNotificationRequest")
	if content_class == nil || request_class == nil {
		return
	}
	content := intrinsics.objc_send(^objc.Object, (^objc.Object)(content_class), "new")
	if content == nil {
		return
	}
	defer intrinsics.objc_send(nil, content, "release")
	intrinsics.objc_send(nil, content, "setTitle:", notify_string(title))
	intrinsics.objc_send(nil, content, "setBody:", notify_string(body))
	n.sequence += 1
	identifier := notify_string(fmt.tprintf("tech.shoji.health.%d", n.sequence))
	request := intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(request_class),
		"requestWithIdentifier:content:trigger:",
		identifier,
		content,
		rawptr(nil),
	)
	if request == nil {
		return
	}
	intrinsics.objc_send(
		nil,
		n.center,
		"addNotificationRequest:withCompletionHandler:",
		request,
		rawptr(nil),
	)
}

// Turns recorded transitions into notifications. Each is consumed once.
notify_payload_transition :: proc(n: ^Notifier, r: ^Addition_Reload, now: time.Time) {
	transition := r.transition
	r.transition = .None
	switch transition {
	case .None:
	case .Failed:
		body := health.bounded_get(&r.payload_health.cause)
		if report := health.bounded_get(&r.payload_health.crash_report); report != "" {
			body = fmt.tprintf("%s. Crash report: %s", body, report)
		}
		notify(n, "Shoji: Dock payload failed", body, now)
	case .Recovered:
		body :: "Native Space and window effects work again."
		notify(n, "Shoji: Dock payload recovered", body, now)
	}
}

notify_config_failures :: proc(n: ^Notifier, run: ^Config_Run, now: time.Time) {
	report := &run.report
	for run.notified < report.count {
		failure := &report.failures[run.notified]
		notify(n, "Shoji: configuration error", health.config_failure_text(failure), now)
		run.notified += 1
	}
}

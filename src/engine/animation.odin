package engine

import "core:math"

Easing :: enum {
	Linear,
	In_Sine,
	Out_Sine,
	In_Out_Sine,
	In_Quad,
	Out_Quad,
	In_Out_Quad,
	In_Cubic,
	Out_Cubic,
	In_Out_Cubic,
	In_Quart,
	Out_Quart,
	In_Out_Quart,
	In_Quint,
	Out_Quint,
	In_Out_Quint,
	In_Expo,
	Out_Expo,
	In_Out_Expo,
	In_Circ,
	Out_Circ,
	In_Out_Circ,
}
EASING_NAMES := []string {
	"linear",
	"ease_in_sine",
	"ease_out_sine",
	"ease_in_out_sine",
	"ease_in_quad",
	"ease_out_quad",
	"ease_in_out_quad",
	"ease_in_cubic",
	"ease_out_cubic",
	"ease_in_out_cubic",
	"ease_in_quart",
	"ease_out_quart",
	"ease_in_out_quart",
	"ease_in_quint",
	"ease_out_quint",
	"ease_in_out_quint",
	"ease_in_expo",
	"ease_out_expo",
	"ease_in_out_expo",
	"ease_in_circ",
	"ease_out_circ",
	"ease_in_out_circ",
}

ease :: proc(kind: Easing, t: f64) -> f64 {
	t := clamp(t, 0, 1)
	if t == 0 || t == 1 {return t}
	#partial switch kind {
	case .Linear:
		return t
	case .In_Sine:
		return 1 - math.cos(t * math.PI / 2)
	case .Out_Sine:
		return math.sin(t * math.PI / 2)
	case .In_Out_Sine:
		return (1 - math.cos(t * math.PI)) / 2
	case .In_Expo:
		return math.pow(2, 10 * t - 10)
	case .Out_Expo:
		return 1 - math.pow(2, -10 * t)
	case .In_Out_Expo:
		return t < 0.5 ? math.pow(2, 20 * t - 10) / 2 : (2 - math.pow(2, -20 * t + 10)) / 2
	case .In_Circ:
		return 1 - math.sqrt(1 - t * t)
	case .Out_Circ:
		return math.sqrt(1 - (t - 1) * (t - 1))
	case .In_Out_Circ:
		return(
			t < 0.5 \
			? (1 - math.sqrt(1 - 4 * t * t)) / 2 \
			: (math.sqrt(1 - math.pow(-2 * t + 2, 2)) + 1) / 2 \
		)
	case:
	}
	index := int(kind) - int(Easing.In_Quad)
	power := f64(index / 3 + 2)
	switch index % 3 {
	case 0:
		return math.pow(t, power)
	case 1:
		return 1 - math.pow(1 - t, power)
	case 2:
		return(
			t < 0.5 \
			? math.pow(2, power - 1) * math.pow(t, power) \
			: 1 - math.pow(-2 * t + 2, power) / 2 \
		)
	}
	return t
}

interpolate_frame :: proc(from, to: Rect, progress: f64, kind: Easing) -> Rect {
	t := ease(kind, progress)
	return {
		from.x + (to.x - from.x) * t,
		from.y + (to.y - from.y) * t,
		from.w + (to.w - from.w) * t,
		from.h + (to.h - from.h) * t,
	}
}

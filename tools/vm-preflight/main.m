#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 2) { fprintf(stderr, "Usage: %s [restore.ipsw]\n", argv[0]); return 64; }
        NSURL *localImage = nil;
        if (argc == 2) {
            NSString *path = [NSString stringWithUTF8String:argv[1]];
            BOOL directory = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&directory] || directory) {
                fprintf(stderr, "Restore image is not a file: %s\n", argv[1]);
                return 66;
            }
            localImage = [NSURL fileURLWithPath:path];
        }
        BOOL supported = VZVirtualMachine.isSupported;
        fprintf(stdout, "Virtualization supported: %s\n", supported ? "yes" : "no");
        fflush(stdout);
        if (!supported) return 2;
        __block BOOL finished = NO;
        __block int status = 0;
        void (^completion)(VZMacOSRestoreImage *, NSError *) = ^(VZMacOSRestoreImage *image, NSError *error) {
            if (error) {
                fprintf(stderr, "Restore-image lookup failed: %s\n", error.description.UTF8String);
                status = 1;
            } else {
                NSOperatingSystemVersion version = image.operatingSystemVersion;
                printf("%s: %ld.%ld.%ld (%s)\n", localImage ? "Selected guest" : "Latest supported guest", version.majorVersion, version.minorVersion, version.patchVersion, image.buildVersion.UTF8String);
                printf("Restore URL: %s\n", image.URL.absoluteString.UTF8String);
                VZMacOSConfigurationRequirements *requirements = image.mostFeaturefulSupportedConfiguration;
                printf("Compatible configuration: %s\n", requirements ? "yes" : "no");
                if (requirements) printf("Minimum CPUs: %lu; minimum RAM: %llu bytes\n", requirements.minimumSupportedCPUCount, requirements.minimumSupportedMemorySize);
                else status = 2;
                if (localImage && (version.majorVersion != 27 || version.minorVersion != 0 || version.patchVersion != 1 || ![image.buildVersion isEqualToString:@"26A434"])) {
                    fprintf(stderr, "Selected image does not match Shoji's 27.0.1 / 26A434 candidate\n");
                    status = 4;
                }
            }
            finished = YES;
        };
        if (localImage) [VZMacOSRestoreImage loadFileURL:localImage completionHandler:completion];
        else [VZMacOSRestoreImage fetchLatestSupportedWithCompletionHandler:completion];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
        while (!finished && deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        if (!finished) { fprintf(stderr, "Restore-image lookup timed out after 30 seconds\n"); return 3; }
        return status;
    }
}

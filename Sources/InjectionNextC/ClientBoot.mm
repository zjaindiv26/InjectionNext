//
//  ClientBoot.m
//  
//
//  Created by John H on 31/05/2024.
//

#if DEBUG || !SWIFT_PACKAGE
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <SystemConfiguration/SystemConfiguration.h>
#endif

#import "InjectionImplC.h"
#import "InjectionClient.h"
#import "SimpleSocket.h"

@interface InjectionNext : SimpleSocket
@end

@implementation NSObject(InjectionNext)

static SimpleSocket *injectionClient;
static BOOL isConnecting = NO;
static int reconnectAttempts = 0;
static const int MAX_RECONNECT_ATTEMPTS = 10;

#if TARGET_OS_IPHONE
// Network reachability callback (iOS only)
static void ReachabilityCallback(SCNetworkReachabilityRef target,
                                 SCNetworkReachabilityFlags flags,
                                 void *info) {
    // Network status changed
    BOOL isReachable = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
    BOOL needsConnection = (flags & kSCNetworkReachabilityFlagsConnectionRequired) == 0;
    BOOL canConnect = isReachable && needsConnection;
    
    if (canConnect) {
        // Network is available, attempt reconnect if not connected
        @synchronized([NSObject class]) {
            if (injectionClient == nil && !isConnecting) {
                reconnectAttempts = 0; // Reset retry count on network change
                [[NSObject class] performSelectorInBackground:@selector(connectToInjection:)
                                                    withObject:[InjectionNext class]];
            }
        }
    }
}
#endif

/// Called on load of image containing this code
+ (void)load {
    NSLog(@"🔥 InjectionNext: +load called");
    if ([InjectionNext InjectionBoot_inPreview]) {
        NSLog(@"🔥 InjectionNext: Running in preview, skipping initialization");
        return;
    }
    #if TARGET_OS_IPHONE
    NSLog(@"🔥 InjectionNext: Scheduling connection on main thread");
    [self performSelectorOnMainThread:@selector(connectInBackground)
                           withObject:nil waitUntilDone:NO];
    #endif
}

#if TARGET_OS_IPHONE
+ (void)connectInBackground {
    NSLog(@"🔥 InjectionNext: connectInBackground called, waiting for app launch notification");
    // iOS 14+ only shows local network permission dialog after
    // UIApplicationDidFinishLaunchingNotification. Wait for this notification
    // before attempting connection to ensure the dialog appears.
    static id<NSObject> observer = nil;
    if (observer == nil) {
        observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil
            queue:nil
            usingBlock:^(NSNotification *note) {
                NSLog(@"🔥 InjectionNext: App launch notification received, starting connection");
                [self performSelectorInBackground:@selector(connectToInjection:)
                                       withObject:[InjectionNext self]];
                [self setupNetworkMonitoring];
                // Remove observer after first use
                [[NSNotificationCenter defaultCenter] removeObserver:observer];
            }];
    }
}

/// Monitor network changes to trigger reconnection on WiFi changes (iOS only)
+ (void)setupNetworkMonitoring {
    static SCNetworkReachabilityRef reachability = NULL;
    if (reachability != NULL) {
        return; // Already monitoring
    }
    
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault,
                                                          (const struct sockaddr *)&zeroAddress);
    if (reachability == NULL) {
        return;
    }
    
    SCNetworkReachabilityContext context = {0, NULL, NULL, NULL, NULL};
    if (SCNetworkReachabilitySetCallback(reachability, ReachabilityCallback, &context)) {
        SCNetworkReachabilityScheduleWithRunLoop(reachability, CFRunLoopGetMain(),
                                                 kCFRunLoopCommonModes);
    }
}
#endif

/// Attempt to connect to InjectionNext.app with retry and exponential backoff
+ (void)connectToInjection:(Class)clientClass {
    @synchronized(self) {
        if (isConnecting) {
            return; // Already attempting connection
        }
        isConnecting = YES;
    }
    
    NSLog(@"🔥 InjectionNext: Starting connection attempt...");
    
    const char *hostip = getenv(INJECTION_HOST) ?: "127.0.0.1";

    // Do we need to use broadcasts to find devlepers Mac on the network
    #if !TARGET_IPHONE_SIMULATOR && !TARGET_OS_OSX
    if (@available(iOS 14.0, *)) if (![NSProcessInfo processInfo].isiOSAppOnMac) {
        printf(APP_PREFIX APP_NAME": Locating developer's Mac. Have you selected \"Enable Devices\"?\n");
        hostip = [SimpleSocket getMulticastService:HOTRELOADING_MULTICAST port:HOTRELOADING_PORT
                                           message:APP_PREFIX"Connecting to %s (%s)...\n"].UTF8String;
    }
    #endif

    // Have the address to connect to, connect with retry and exponential backoff
    NSString *socketAddr = [NSString stringWithFormat:@"%s%s", hostip, INJECTION_ADDRESS];
    NSLog(@"🔥 InjectionNext: Attempting to connect to %@", socketAddr);
    
    while (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
        if (reconnectAttempts > 0) {
            // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (max)
            NSTimeInterval delay = MIN(pow(2.0, reconnectAttempts - 1), 30.0);
            NSLog(@"🔥 InjectionNext: Retry %d/%d after %.0fs delay", reconnectAttempts + 1, MAX_RECONNECT_ATTEMPTS, delay);
            [NSThread sleepForTimeInterval:delay];
        }
        
        if (SimpleSocket *client = [clientClass connectTo:socketAddr]) {
            NSLog(@"🔥 InjectionNext: Connected successfully!");
            reconnectAttempts = 0; // Reset on successful connection
            @synchronized(self) {
                isConnecting = NO;
                injectionClient = client;
            }
            [client run]; // Start processing commands
            
            // Connection dropped, attempt reconnect
            NSLog(@"🔥 InjectionNext: Connection dropped, attempting to reconnect...");
            @synchronized(self) {
                injectionClient = nil;
                isConnecting = NO;
            }
            [self performSelectorInBackground:@selector(connectToInjection:)
                                   withObject:clientClass];
            return;
        }
        
        NSLog(@"🔥 InjectionNext: Connection attempt %d failed", reconnectAttempts + 1);
        reconnectAttempts++;
    }
    
    // Max retries reached
    NSLog(@"🔥 InjectionNext: Max retries (%d) reached. Giving up.", MAX_RECONNECT_ATTEMPTS);
    reconnectAttempts = 0;
    @synchronized(self) {
        isConnecting = NO;
    }
    
    #if TARGET_IPHONE_SIMULATOR || TARGET_OS_MAC
    // If InjectionLite class present, start it up.
    if (getenv(INJECTION_NOSTANDALONE)) return;
    if (Class InjectionLite = objc_getClass("InjectionLite")) {
        printf(APP_PREFIX"Unable to connect to app, running standalone... "
               "Set env var " INJECTION_NOSTANDALONE " to avoid this.\n");
        static NSObject *singleton;
        singleton = [[InjectionLite alloc] init];
    }
    #endif
}

@end
#endif

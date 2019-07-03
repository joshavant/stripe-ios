//
//  STPPaymentHandler.h
//  StripeiOS
//
//  Created by Cameron Sabol on 5/10/19.
//  Copyright © 2019 Stripe, Inc. All rights reserved.
//

#import "STPPaymentHandler.h"

#import <SafariServices/SafariServices.h>
#import <Stripe3DS2/Stripe3DS2.h>

#import "NSError+Stripe.h"
#import "STP3DS2AuthenticateResponse.h"
#import "STPAPIClient+Private.h"
#import "STPAuthenticationContext.h"
#import "STPPaymentIntent.h"
#import "STPPaymentHandlerActionParams.h"
#import "STPIntentAction+Private.h"
#import "STPIntentActionRedirectToURL.h"
#import "STPIntentActionUseStripeSDK.h"
#import "STPSetupIntent.h"
#import "STPSetupIntentConfirmParams.h"
#import "STPThreeDSCustomizationSettings.h"
#import "STPThreeDSCustomization+Private.h"
#import "STPURLCallbackHandler.h"

NS_ASSUME_NONNULL_BEGIN

NSString * const STPPaymentHandlerErrorDomain = @"STPPaymentHandlerErrorDomain";

@interface STPPaymentHandler () <SFSafariViewControllerDelegate, STPURLCallbackListener, STDSChallengeStatusReceiver>
{
    NSObject<STPPaymentHandlerActionParams> *_currentAction;
}

@end

@implementation STPPaymentHandler

+ (instancetype)sharedHandler {
    static STPPaymentHandler *sharedHandler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedHandler = [self new];
        sharedHandler->_apiClient = [STPAPIClient sharedClient];
        sharedHandler.threeDSCustomizationSettings = [STPThreeDSCustomizationSettings defaultSettings];
    });

    return sharedHandler;
}

- (void)confirmPayment:(STPPaymentIntentParams *)paymentParams
withAuthenticationContext:(id<STPAuthenticationContext>)authenticationContext
            completion:(STPPaymentHandlerActionPaymentIntentCompletionBlock)completion {
    if (_currentAction != nil) {
        completion(STPPaymentHandlerActionStatusFailed, nil, [self _errorForCode:STPPaymentHandlerNoConcurrentActionsErrorCode userInfo:nil]);
        return;
    }
    __weak __typeof(self) weakSelf = self;
    STPPaymentIntentCompletionBlock confirmCompletionBlock = ^(STPPaymentIntent * _Nullable paymentIntent, NSError * _Nullable error) {
        __typeof(self) strongSelf = weakSelf;
        if (error) {
            completion(STPPaymentHandlerActionStatusFailed, paymentIntent, error);
        } else {
            [strongSelf handleNextActionForPayment:paymentIntent
                   withAuthenticationContext:authenticationContext
                                  completion:^(STPPaymentHandlerActionStatus status, STPPaymentIntent *completedPaymentIntent, NSError *completedError) {
                                      completion(status, completedPaymentIntent, completedError);
                                  }];
        }
    };
    [self.apiClient confirmPaymentIntentWithParams:paymentParams
                                        completion:confirmCompletionBlock];
}

- (void)handleNextActionForPayment:(STPPaymentIntent *)paymentIntent
         withAuthenticationContext:(id<STPAuthenticationContext>)authenticationContext
                        completion:(STPPaymentHandlerActionPaymentIntentCompletionBlock)completion {
    NSAssert(_currentAction == nil, @"Should not handle multiple payments at once.");
    if (_currentAction != nil) {
        completion(STPPaymentHandlerActionStatusFailed, nil, [self _errorForCode:STPPaymentHandlerNoConcurrentActionsErrorCode userInfo:nil]);
        return;
    }
    if (paymentIntent.status == STPPaymentIntentStatusRequiresPaymentMethod) {
        // The caller forgot to attach a paymentMethod.
        completion(STPPaymentHandlerActionStatusFailed, paymentIntent, [self _errorForCode:STPPaymentHandlerRequiresPaymentMethodErrorCode userInfo:nil]);
        return;
    }

    __weak __typeof(self) weakSelf = self;
    STPPaymentHandlerPaymentIntentActionParams *action = [[STPPaymentHandlerPaymentIntentActionParams alloc] initWithAPIClient:self.apiClient
                                                                                                         authenticationContext:authenticationContext
                                                                                                  threeDSCustomizationSettings:self.threeDSCustomizationSettings
                                                                                                                 paymentIntent:paymentIntent
                                                                                                                    completion:^(STPPaymentHandlerActionStatus status, STPPaymentIntent * _Nullable resultPaymentIntent, NSError * _Nullable error) {
                                                                                                                        __typeof(self) strongSelf = weakSelf;
                                                                                                                        if (strongSelf != nil) {
                                                                                                                            strongSelf->_currentAction = nil;
                                                                                                                        }
                                                                                                                        completion(status, resultPaymentIntent, error);
                                                                                                                    }];
    _currentAction = action;
    BOOL requiresAction = [self _handlePaymentIntentStatusForAction:action];
    if (requiresAction) {
        [self _handleAuthenticationForCurrentAction];
    }
}

- (void)confirmSetupIntent:(STPSetupIntentConfirmParams *)setupIntentConfirmParams
 withAuthenticationContext:(id<STPAuthenticationContext>)authenticationContext
                completion:(STPPaymentHandlerActionSetupIntentCompletionBlock)completion {
    NSAssert(_currentAction == nil, @"Should not handle multiple payments at once.");
    if (_currentAction != nil) {
        completion(STPPaymentHandlerActionStatusFailed, nil, [self _errorForCode:STPPaymentHandlerNoConcurrentActionsErrorCode userInfo:nil]);
        return;
    }
    __weak __typeof(self) weakSelf = self;
    STPSetupIntentCompletionBlock confirmCompletionBlock = ^(STPSetupIntent * _Nullable setupIntent, NSError * _Nullable error) {
        __typeof(self) strongSelf = weakSelf;
        if (error) {
            completion(STPPaymentHandlerActionStatusFailed, setupIntent, error);
        } else {
            STPPaymentHandlerSetupIntentActionParams *action = [[STPPaymentHandlerSetupIntentActionParams alloc] initWithAPIClient:self.apiClient
                                                                                                             authenticationContext:authenticationContext
                                                                                                      threeDSCustomizationSettings:self.threeDSCustomizationSettings
                                                                                                                       setupIntent:setupIntent
                                                                                                                        completion:^(STPPaymentHandlerActionStatus status, STPSetupIntent * _Nullable resultSetupIntent, NSError * _Nullable resultError) {
                                                                                                                            if (strongSelf != nil) {
                                                                                                                                strongSelf->_currentAction = nil;
                                                                                                                            }
                                                                                                                            completion(status, resultSetupIntent, resultError);
                                                                                                                        }];
            strongSelf->_currentAction = action;
            BOOL requiresAction = [strongSelf _handleSetupIntentStatusForAction:action];
            if (requiresAction) {
                [strongSelf _handleAuthenticationForCurrentAction];
            }
        }
    };
    [self.apiClient confirmSetupIntentWithParams:setupIntentConfirmParams completion:confirmCompletionBlock];
}


#pragma mark - Private Helpers

/// Calls the current action's completion handler for the SetupIntent status, or returns YES if the status is ...RequiresAction.
- (BOOL)_handleSetupIntentStatusForAction:(STPPaymentHandlerSetupIntentActionParams *)action {
    STPSetupIntent *setupIntent = action.setupIntent;
    if (setupIntent == nil) {
        NSAssert(setupIntent != nil, @"setupIntent should never be nil here.");
        [action completeWithStatus:STPPaymentHandlerActionStatusFailed error:[NSError stp_genericFailedToParseResponseError]];
        return NO;
    }
    switch (setupIntent.status) {
        case STPSetupIntentStatusUnknown:
           [action completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerIntentStatusErrorCode userInfo:@{@"STPSetupIntent": setupIntent.description}]];
        case STPSetupIntentStatusRequiresPaymentMethod:
            // If the user forgot to attach a PaymentMethod, they get an error before this point.
            // If authentication fails, the SetupIntent transitions to this state.
            [action completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerNotAuthenticatedErrorCode userInfo:nil]];
            break;
        case STPSetupIntentStatusRequiresConfirmation:
            [action completeWithStatus:STPPaymentHandlerActionStatusSucceeded error:nil];
            break;
        case STPSetupIntentStatusRequiresAction:
            return YES;
        case STPSetupIntentStatusProcessing:
            [action completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerIntentStatusErrorCode userInfo:nil]];
            break;
        case STPSetupIntentStatusSucceeded:
            [action completeWithStatus:STPPaymentHandlerActionStatusSucceeded error:nil];
            break;
        case STPSetupIntentStatusCanceled:
            [action completeWithStatus:STPPaymentHandlerActionStatusCanceled error:nil];
            break;
    }
    return NO;
}

/// Calls the current action's completion handler for the PaymentIntent status, or returns YES if the status is ...RequiresAction.
- (BOOL)_handlePaymentIntentStatusForAction:(STPPaymentHandlerPaymentIntentActionParams *)action {
    STPPaymentIntent *paymentIntent = action.paymentIntent;
    if (paymentIntent == nil) {
        NSAssert(paymentIntent != nil, @"paymentIntent should never be nil here.");
        [_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:[NSError stp_genericFailedToParseResponseError]];
        return NO;
    }
    switch (paymentIntent.status) {

        case STPPaymentIntentStatusUnknown:
            [action completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerIntentStatusErrorCode userInfo:@{@"STPPaymentIntent": paymentIntent.description}]];
            break;

        case STPPaymentIntentStatusRequiresPaymentMethod:
            // If the user forgot to attach a PaymentMethod, they get an error before this point.
            // If authentication fails, the PaymentIntent transitions to this state.
            [action completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerNotAuthenticatedErrorCode userInfo:nil]];
            break;
        case STPPaymentIntentStatusRequiresConfirmation:
            [action completeWithStatus:STPPaymentHandlerActionStatusSucceeded error:nil];
            break;
        case STPPaymentIntentStatusRequiresAction:
            return YES;
        case STPPaymentIntentStatusProcessing:
            [action completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerIntentStatusErrorCode userInfo:nil]];
            break;
        case STPPaymentIntentStatusSucceeded:
            [action completeWithStatus:STPPaymentHandlerActionStatusSucceeded error:nil];
            break;
        case STPPaymentIntentStatusRequiresCapture:
            [action completeWithStatus:STPPaymentHandlerActionStatusSucceeded error:nil];
            break;
        case STPPaymentIntentStatusCanceled:
            [action completeWithStatus:STPPaymentHandlerActionStatusCanceled error:nil];
            break;
        }
    return NO;
}

- (void)_handleAuthenticationForCurrentAction {
    STPIntentAction *authenticationAction = _currentAction.nextAction;

    // Checking for authenticationPresentingViewController instead of just authenticationContext == nil
    // also allows us to catch contexts that are not behaving correctly (i.e. returning nil vc when they shouldn't)
    UIViewController *presentingViewController = [_currentAction.authenticationContext authenticationPresentingViewController];
    if (presentingViewController == nil || presentingViewController.view.window == nil) {
        [_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerRequiresAuthenticationContextErrorCode userInfo:nil]];
        return;
    }

    switch (authenticationAction.type) {

        case STPIntentActionTypeUnknown:
            [_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerUnsupportedAuthenticationErrorCode userInfo:@{@"STPIntentAction": authenticationAction.description}]];
            break;
        case STPIntentActionTypeRedirectToURL: {
            NSURL *url = authenticationAction.redirectToURL.url;

            [[STPURLCallbackHandler shared] registerListener:self forURL:authenticationAction.redirectToURL.returnURL];

            [[UIApplication sharedApplication] openURL:url
                                               options:@{UIApplicationOpenURLOptionUniversalLinksOnly: @(YES)}
                                     completionHandler:^(BOOL success){
                                         if(!success) {
                                             // no app installed, launch safari view controller
                                             SFSafariViewController *safariViewController = [[SFSafariViewController alloc] initWithURL:authenticationAction.redirectToURL.url];
                                             safariViewController.delegate = self;
                                             [[self->_currentAction.authenticationContext authenticationPresentingViewController] presentViewController:safariViewController animated:YES completion:nil];
                                         } else {
                                             [[NSNotificationCenter defaultCenter] addObserver:self
                                                                                      selector:@selector(_handleWillForegroundNotification)
                                                                                          name:UIApplicationWillEnterForegroundNotification
                                                                                        object:nil];
                                         }
                                     }];

        }
            break;

        case STPIntentActionTypeUseStripeSDK:

            switch (authenticationAction.useStripeSDK.type) {
                case STPIntentActionUseStripeSDKTypeUnknown:
                    [_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerUnsupportedAuthenticationErrorCode userInfo:@{@"STPIntentActionUseStripeSDK": authenticationAction.useStripeSDK.description}]];
                    break;
                case STPIntentActionUseStripeSDKType3DS2Fingerprint: {
                    STDSThreeDS2Service *threeDSService = _currentAction.threeDS2Service;
                    if (threeDSService == nil) {
                        [_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerStripe3DS2ErrorCode userInfo:@{@"description": @"Failed to initialize STDSThreeDS2Service."}]];
                        return;
                    }

                    STDSTransaction *transaction = nil;
                    STDSAuthenticationRequestParameters *authRequestParams = nil;
                    @try {
                        transaction = [threeDSService createTransactionForDirectoryServer:authenticationAction.useStripeSDK.directoryServer
                                                                      withProtocolVersion:@"2.1.0"];

                        authRequestParams = [transaction createAuthenticationRequestParameters];

                    } @catch (NSException *exception) {
                        [_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerStripe3DS2ErrorCode userInfo:@{@"exception": exception.description}]];
                    }

                    [_apiClient authenticate3DS2:authRequestParams
                                sourceIdentifier:authenticationAction.useStripeSDK.threeDS2SourceID
                                      maxTimeout:_currentAction.threeDSCustomizationSettings.authenticationTimeout
                                      completion:^(STP3DS2AuthenticateResponse * _Nullable authenticateResponse, NSError * _Nullable error) {
                                          if (authenticateResponse == nil) {
                                              [self->_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:error];
                                          } else {
                                              STDSChallengeParameters *challengeParameters = [[STDSChallengeParameters alloc] initWithAuthenticationResponse:authenticateResponse.authenticationResponse];
                                              @try {
                                                  [transaction doChallengeWithViewController:[self->_currentAction.authenticationContext authenticationPresentingViewController]
                                                                         challengeParameters:challengeParameters
                                                                     challengeStatusReceiver:self
                                                                                     timeout:self->_currentAction.threeDSCustomizationSettings.authenticationTimeout];
                                              } @catch (NSException *exception) {
                                                  [self->_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerStripe3DS2ErrorCode  userInfo:@{@"exception": exception}]];
                                              }

                                          }
                                      }];
                }
                    break;
            }
            break;
    }
}

- (void)_retrieveAndCheckIntentForCurrentAction {
    if ([_currentAction isKindOfClass:[STPPaymentHandlerPaymentIntentActionParams class]]) {
        STPPaymentHandlerPaymentIntentActionParams *currentAction = (STPPaymentHandlerPaymentIntentActionParams *)_currentAction;
        [_currentAction.apiClient retrievePaymentIntentWithClientSecret:currentAction.paymentIntent.clientSecret
                                                             completion:^(STPPaymentIntent * _Nullable paymentIntent, NSError * _Nullable error) {
                                                                 if (error != nil) {
                                                                     [currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:error];
                                                                 } else {
                                                                     currentAction.paymentIntent = paymentIntent;
                                                                     BOOL requiresAction = [self _handlePaymentIntentStatusForAction:currentAction];
                                                                     if (requiresAction) {
                                                                         // If the status is still RequiresAction, the user exited from the redirect before the
                                                                         // payment intent was updated. Consider it a cancel
                                                                         [currentAction completeWithStatus:STPPaymentHandlerActionStatusCanceled error:nil];
                                                                     }
                                                                 }
                                                             }];
    } else if ([_currentAction isKindOfClass:[STPPaymentHandlerSetupIntentActionParams class]]) {
        STPPaymentHandlerSetupIntentActionParams *currentAction = (STPPaymentHandlerSetupIntentActionParams *)_currentAction;
        [_currentAction.apiClient retrieveSetupIntentWithClientSecret:currentAction.setupIntent.clientSecret
                                                           completion:^(STPSetupIntent * _Nullable setupIntent, NSError * _Nullable error) {
                                                               if (error != nil) {
                                                                   [currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:error];
                                                               } else {
                                                                   currentAction.setupIntent = setupIntent;
                                                                   BOOL requiresAction = [self _handleSetupIntentStatusForAction:currentAction];
                                                                   if (requiresAction) {
                                                                       // If the status is still RequiresAction, the user exited from the redirect before the
                                                                       // setup intent was updated. Consider it a cancel
                                                                       [currentAction completeWithStatus:STPPaymentHandlerActionStatusCanceled error:nil];
                                                                   }
                                                               }
                                                           }];
        
    } else {
        NSAssert(NO, @"currentAction is an unknown type or nil.");
    }
}

- (void)_handleWillForegroundNotification {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [self _retrieveAndCheckIntentForCurrentAction];
}

#pragma mark - SFSafariViewControllerDelegate

- (void)safariViewControllerDidFinish:(SFSafariViewController * __unused)controller {
    [[STPURLCallbackHandler shared] unregisterListener:self];
    [self _retrieveAndCheckIntentForCurrentAction];
}

#pragma mark - STPURLCallbackListener

- (BOOL)handleURLCallback:(NSURL * __unused)url {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [[STPURLCallbackHandler shared] unregisterListener:self];
    [[_currentAction.authenticationContext authenticationPresentingViewController] dismissViewControllerAnimated:YES completion:nil];
    [self _retrieveAndCheckIntentForCurrentAction];
    return YES;
}

#pragma mark - STPChallengeStatusReceiver

- (void)transaction:(__unused STDSTransaction *)transaction didCompleteChallengeWithCompletionEvent:(STDSCompletionEvent *)completionEvent {
    NSString *transactionStatus = completionEvent.transactionStatus;
    __weak __typeof(self) weakSelf = self;
    if ([transactionStatus isEqualToString:@"Y"]) {
        [self _markChallengeCompletedWithCompletion:^(BOOL markedCompleted, NSError * _Nullable error) {
            __typeof(self) strongSelf = weakSelf;
            [strongSelf->_currentAction completeWithStatus:markedCompleted ? STPPaymentHandlerActionStatusSucceeded : STPPaymentHandlerActionStatusFailed error:error];
        }];

    } else {
        // going to ignore the rest of the status types because they provide more detail than we require
        [self _markChallengeCompletedWithCompletion:^(__unused BOOL markedCompleted, __unused NSError * _Nullable error) {
            __typeof(self) strongSelf = weakSelf;
            [strongSelf->_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerNotAuthenticatedErrorCode userInfo:@{@"transaction_status": transactionStatus}]];
        }];
    }
}

- (void)transactionDidCancel:(__unused STDSTransaction *)transaction {
    __weak __typeof(self) weakSelf = self;
    [self _markChallengeCompletedWithCompletion:^(__unused BOOL markedCompleted, __unused NSError * _Nullable error) {
        __typeof(self) strongSelf = weakSelf;
        [strongSelf->_currentAction completeWithStatus:STPPaymentHandlerActionStatusCanceled error:nil];
    }];
}

- (void)transactionDidTimeOut:(__unused STDSTransaction *)transaction {
    __weak __typeof(self) weakSelf = self;
    [self _markChallengeCompletedWithCompletion:^(__unused BOOL markedCompleted, __unused NSError * _Nullable error) {
        __typeof(self) strongSelf = weakSelf;
        [strongSelf->_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:[self _errorForCode:STPPaymentHandlerTimedOutErrorCode userInfo:nil]];
    }];

}

- (void)transaction:(__unused STDSTransaction *)transaction didErrorWithProtocolErrorEvent:(STDSProtocolErrorEvent *)protocolErrorEvent {
    __weak __typeof(self) weakSelf = self;
    [self _markChallengeCompletedWithCompletion:^(__unused BOOL markedCompleted, __unused NSError * _Nullable error) {
        __typeof(self) strongSelf = weakSelf;
        // Add localizedError to the 3DS2 SDK error
        NSError *threeDSError = [protocolErrorEvent.errorMessage NSErrorValue];
        NSMutableDictionary *userInfo = [threeDSError.userInfo mutableCopy];
        userInfo[NSLocalizedDescriptionKey] = [NSError stp_unexpectedErrorMessage];
        NSError *localizedError = [NSError errorWithDomain:threeDSError.domain code:threeDSError.code userInfo:userInfo];
        [strongSelf->_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:localizedError];
    }];
}

- (void)transaction:(__unused STDSTransaction *)transaction didErrorWithRuntimeErrorEvent:(STDSRuntimeErrorEvent *)runtimeErrorEvent {
    __weak __typeof(self) weakSelf = self;
    [self _markChallengeCompletedWithCompletion:^(__unused BOOL markedCompleted, __unused NSError * _Nullable error) {
        __typeof(self) strongSelf = weakSelf;
        // Add localizedError to the 3DS2 SDK error
        NSError *threeDSError = [runtimeErrorEvent NSErrorValue];
        NSMutableDictionary *userInfo = [threeDSError.userInfo mutableCopy];
        userInfo[NSLocalizedDescriptionKey] = [NSError stp_unexpectedErrorMessage];
        NSError *localizedError = [NSError errorWithDomain:threeDSError.domain code:threeDSError.code userInfo:userInfo];
        [strongSelf->_currentAction completeWithStatus:STPPaymentHandlerActionStatusFailed error:localizedError];
    }];
}

- (void)_markChallengeCompletedWithCompletion:(STPBooleanSuccessBlock)completion {
    NSString *threeDSSourceID = _currentAction.nextAction.useStripeSDK.threeDS2SourceID;
    if (threeDSSourceID == nil) {
        completion(NO, nil);
        return;
    }

    [_currentAction.apiClient complete3DS2AuthenticationForSource:threeDSSourceID completion:^(BOOL success, NSError * _Nullable error) {
        if (success) {
            if ([self->_currentAction isKindOfClass:[STPPaymentHandlerPaymentIntentActionParams class]]) {
                STPPaymentHandlerPaymentIntentActionParams *currentAction = (STPPaymentHandlerPaymentIntentActionParams *)self->_currentAction;
                [currentAction.apiClient retrievePaymentIntentWithClientSecret:currentAction.paymentIntent.clientSecret
                                                                    completion:^(STPPaymentIntent * _Nullable paymentIntent, NSError * _Nullable retrieveError) {
                                                                        currentAction.paymentIntent = paymentIntent;
                                                                        completion(paymentIntent != nil, retrieveError);
                                                                    }];
            } else if ([self->_currentAction isKindOfClass:[STPPaymentHandlerSetupIntentActionParams class]]) {
                STPPaymentHandlerSetupIntentActionParams *currentAction = (STPPaymentHandlerSetupIntentActionParams *)self->_currentAction;
                [currentAction.apiClient retrieveSetupIntentWithClientSecret:currentAction.setupIntent.clientSecret
                                                                  completion:^(STPSetupIntent * _Nullable setupIntent, NSError * _Nullable retrieveError) {
                                                                      currentAction.setupIntent = setupIntent;
                                                                      completion(setupIntent != nil, retrieveError);
                                                                  }];
            } else {
                NSAssert(NO, @"currentAction is an unknown type or nil.");
            }
        } else {
            completion(success, error);
        }
    }];

}

#pragma mark - Errors

- (NSError *)_errorForCode:(STPPaymentHandlerErrorCode)errorCode userInfo:(nullable NSDictionary *)additionalUserInfo {
    NSMutableDictionary *userInfo = additionalUserInfo ? [additionalUserInfo mutableCopy] : [NSMutableDictionary new];
    switch (errorCode) {
        // 3DS2 flow expected user errors
        case STPPaymentHandlerNotAuthenticatedErrorCode:
            userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"We are unable to authenticate your payment method. Please choose a different payment method and try again.", @"Error when 3DS2 authentication failed (e.g. customer entered the wrong code)");
            break;
        case STPPaymentHandlerTimedOutErrorCode:
            userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Timed out authenticating your payment method -- try again", @"Error when 3DS2 authentication timed out.");
            break;

        // PaymentIntent has an unexpected/unknown status
        case STPPaymentHandlerIntentStatusErrorCode:
            // The PI's status is processing or unknown
            userInfo[STPErrorMessageKey] = @"The PaymentIntent status cannot be handled. ";
            userInfo[NSLocalizedDescriptionKey] = [NSError stp_unexpectedErrorMessage];
            break;
        case STPPaymentHandlerUnsupportedAuthenticationErrorCode:
            userInfo[STPErrorMessageKey] = @"The SDK doesn't recognize the PaymentIntent action type.";
            userInfo[NSLocalizedDescriptionKey] = [NSError stp_unexpectedErrorMessage];
            break;

        // Programming errors
        case STPPaymentHandlerRequiresPaymentMethodErrorCode:
            userInfo[STPErrorMessageKey] = @"The PaymentIntent requires a PaymentMethod or Source to be attached before using STPPaymentHandler.";
            userInfo[NSLocalizedDescriptionKey] = [NSError stp_unexpectedErrorMessage];
            break;
        case STPPaymentHandlerNoConcurrentActionsErrorCode:
            userInfo[STPErrorMessageKey] = @"The current action is not yet completed. STPPaymentHandler does not support concurrent calls to its API.";
            userInfo[NSLocalizedDescriptionKey] = [NSError stp_unexpectedErrorMessage];
            break;
        case STPPaymentHandlerRequiresAuthenticationContextErrorCode:
            userInfo[STPErrorMessageKey] = @"The authenticationContext is invalid.  Make sure it's non-nil and in the window hierarchy.";
            userInfo[NSLocalizedDescriptionKey] = [NSError stp_unexpectedErrorMessage];
            break;
            
        // Exceptions thrown from the Stripe3DS2 SDK. Other errors are reported via STPChallengeStatusReceiver.
        case STPPaymentHandlerStripe3DS2ErrorCode:
            userInfo[STPErrorMessageKey] = @"There was an error in the Stripe3DS2 SDK.";
            userInfo[NSLocalizedDescriptionKey] = [NSError stp_unexpectedErrorMessage];
            break;
    }
    return [NSError errorWithDomain:STPPaymentHandlerErrorDomain
                               code:errorCode
                           userInfo:userInfo];
}

@end

NS_ASSUME_NONNULL_END

//
//  CardManualConfirmationExampleViewController.m
//  Custom Integration
//
//  Created by Ben Guo on 2/22/17.
//  Copyright © 2017 Stripe. All rights reserved.
//

#import <Stripe/Stripe.h>
#import "CardManualConfirmationExampleViewController.h"
#import "BrowseExamplesViewController.h"

/**
 This example demonstrates creating a payment with a credit/debit card using Manual Integration.
 It creates a Payment Method using card information collected with STPPaymentCardTextField, and
 then sends the Payment Method ID to our example backend to create and confirm the Payment Intent.
 */
@interface CardManualConfirmationExampleViewController () <STPPaymentCardTextFieldDelegate, UIScrollViewDelegate>
@property (weak, nonatomic) STPPaymentCardTextField *paymentTextField;
@property (weak, nonatomic) UIActivityIndicatorView *activityIndicator;
@property (weak, nonatomic) UIScrollView *scrollView;
@end

@implementation CardManualConfirmationExampleViewController

- (void)loadView {
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.delegate = self;
    scrollView.alwaysBounceVertical = YES;
    scrollView.backgroundColor = [UIColor whiteColor];
    self.view = scrollView;
    self.scrollView = scrollView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Card - Manual Integration";
    self.edgesForExtendedLayout = UIRectEdgeNone;

    UIBarButtonItem *buyButton = [[UIBarButtonItem alloc] initWithTitle:@"Pay" style:UIBarButtonItemStyleDone target:self action:@selector(pay)];
    buyButton.enabled = NO;
    self.navigationItem.rightBarButtonItem = buyButton;

    STPPaymentCardTextField *paymentTextField = [[STPPaymentCardTextField alloc] init];
    paymentTextField.delegate = self;
    paymentTextField.cursorColor = [UIColor purpleColor];
    paymentTextField.postalCodeEntryEnabled = YES;
    self.paymentTextField = paymentTextField;
    [self.view addSubview:paymentTextField];

    UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    activityIndicator.hidesWhenStopped = YES;
    self.activityIndicator = activityIndicator;
    [self.view addSubview:activityIndicator];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat padding = 15;
    CGFloat width = CGRectGetWidth(self.view.frame) - (padding*2);
    CGRect bounds = self.view.bounds;
    self.paymentTextField.frame = CGRectMake(padding, padding, width, 44);
    self.activityIndicator.center = CGPointMake(CGRectGetMidX(bounds),
                                                CGRectGetMaxY(self.paymentTextField.frame) + padding*2);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.paymentTextField becomeFirstResponder];
}

- (void)paymentCardTextFieldDidChange:(nonnull STPPaymentCardTextField *)textField {
    self.navigationItem.rightBarButtonItem.enabled = textField.isValid;
}

- (void)pay {
    if (![self.paymentTextField isValid]) {
        return;
    }
    if (![Stripe defaultPublishableKey]) {
        [self.delegate exampleViewController:self didFinishWithMessage:@"Please set a Stripe Publishable Key in Constants.m"];
        return;
    }
    [self.activityIndicator startAnimating];

    STPPaymentMethodParams *paymentMethodParams = [STPPaymentMethodParams paramsWithCard:self.paymentTextField.cardParams
                                                                          billingDetails:nil
                                                                                metadata:nil];
    [[STPAPIClient sharedClient] createPaymentMethodWithParams:paymentMethodParams
                                                    completion:^(STPPaymentMethod * _Nullable paymentMethod, NSError * _Nullable error) {
                                                        if (error) {
                                                            [self.delegate exampleViewController:self didFinishWithError:error];
                                                        } else {
                                                            [self _createAndConfirmPaymentIntentWithPaymentMethod:paymentMethod];
                                                        }
                                                    }];
}


- (void)_createAndConfirmPaymentIntentWithPaymentMethod:(STPPaymentMethod *)paymentMethod {

    [self.delegate createAndConfirmPaymentIntentWithAmount:@(100)
                                             paymentMethod:paymentMethod.stripeId
                                                 returnURL:@"payments-example://stripe-redirect"
                                                completion:^(STPBackendResult status, STPPaymentIntent *paymentIntent, NSError *error) {
                                                    if (status == STPBackendResultFailure || error) {
                                                        [self.delegate exampleViewController:self didFinishWithError:error];
                                                        return;
                                                    }

                                                    if (paymentIntent.status == STPPaymentIntentStatusRequiresAction) {
                                                        [[STPPaymentHandler sharedHandler] handleNextActionForPayment:paymentIntent
                                                                                            withAuthenticationContext:self.delegate
                                                                                                           completion:^(STPPaymentHandlerActionStatus handlerStatus, STPPaymentIntent * _Nullable handledIntent, NSError * _Nullable handlerError) {
                                                                                                               if (handlerError != nil || handlerStatus == STPPaymentHandlerActionStatusFailed) {
                                                                                                                   [self.delegate exampleViewController:self didFinishWithError:handlerError];
                                                                                                               } else if (handlerStatus == STPPaymentHandlerActionStatusCanceled) {
                                                                                                                   [self.delegate exampleViewController:self didFinishWithMessage:@"Canceled authentication"];
                                                                                                                  } else {
                                                                                                                      [self.delegate exampleViewController:self didFinishWithMessage:@"Payment successfully created"];
                                                                                                                  }
                                                                                                           }];
                                                    } else {
                                                        [self.delegate exampleViewController:self didFinishWithMessage:@"Payment successfully created"];
                                                    }
                                                }];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self.view endEditing:NO];
}

@end

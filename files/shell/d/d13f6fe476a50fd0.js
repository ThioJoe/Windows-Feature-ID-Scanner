//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'legacy/bridge', 'legacy/events', 'legacy/core', 'corejs/knockouthelpers'], (ko, bridge, constants, core, KoHelpers) => {
    class HelloViewModel {
        constructor(resourceStrings, enrollmentKinds, targetPersonality) {
            this.isLiteWhitePersonality = (targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite);

            this.resourceStrings = resourceStrings;
            this.enrollmentKinds = enrollmentKinds;
            this.processingFlag = ko.observable(false);
            this.contentContainerVisibility = ko.observable(true);
            this.flexStartHyperLinks = [];
            this.title = ko.observable("");
            this.leadText = ko.observable("");
            this.flexEndButtons = ko.observableArray([]);
            this.subtitle = ko.observable("");

            this.isMultiChoice = (this.enrollmentKinds.face && this.enrollmentKinds.fingerprint);
            this.isFaceSelected = true;
            this.hideContentWhileBioAppIsLaunched = !this.isLiteWhitePersonality;
            this.showConfirmationPage = this.isLiteWhitePersonality;
            this.skipOnIncompleteEnrollment = this.isLiteWhitePersonality;
            this.switchEnrollmentKindText = ko.observable(resourceStrings.HelloSwitchFaceToFingerprint);
            this.isConfirmationPageVisible = ko.observable(false);

            let href = "https://go.microsoft.com/fwlink/p/?linkid=2169254";
            let personalityQSParam = (this.isLiteWhitePersonality) ? "&profile=transparentLight" : "";
            let url = href + personalityQSParam;

            this.learnMoreWebSource = url;
            this.learnMoreVisible = ko.observable(false);
            this.learnMoreVisible.subscribe((newValue) => {
                if (newValue === false) {
                    // Reenable button interaction if we're not showing Learn More. On the Learn More page,
                    // buttons will be enabled after the iframe is shown after oobeSettingsData.showLearnMoreContent()
                    this.processingFlag(false);
                }
            });
            this.flexEndButtonsLearnMore = {
                buttonText: resourceStrings.HelloContinueButtonText,
                buttonType: "button",
                isPrimaryButton: true,
                autoFocus: true,
                buttonClickHandler: (() => {
                    this.onLearnMoreContinue();
                }),
                disableControl: ko.pureComputed(() => {
                    return this.processingFlag();
                })
            };

            if (this.isMultiChoice) {
                if (!this.isLiteWhitePersonality) {
                    this.title(resourceStrings.HelloTitleMulti);
                    this.items = [
                        {
                            face: true,
                            fingerprint: false,
                            ariaLabel: resourceStrings.HelloFaceIconAriaLabel,
                            title: resourceStrings.HelloOptionTitleFace,
                            description: resourceStrings.HelloLeadTextFace
                        },
                        {
                            face: false,
                            fingerprint: true,
                            ariaLabel: resourceStrings.HelloFingerprintIconAriaLabel,
                            title: resourceStrings.HelloOptionTitleFingerprint,
                            description: resourceStrings.HelloOptionBodyFingerprint
                        }
                    ];

                    this.selectedItem = ko.observable(this.items[0]);
                    this.selectedItem.subscribe((newSelectedItem) => {
                        if (this.selectedItem().title != newSelectedItem.title) {
                            if (newSelectedItem.face) {
                                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentDisambiguationFaceSelected");
                            } else if (newSelectedItem.fingerprint) {
                                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentDisambiguationFingerprintSelected");
                            }
                        }
                    });
                } else {
                    // isMultiChoice && isLiteWhitePersonality
                    // By default, render Hello Face as the selected one
                    this.renderFace();
                }
            } else {
                // !isMultiChoice
                // Only one among Face or Fingerprint is available
                if (this.enrollmentKinds.face) {
                    this.renderFace();
                } else if (this.enrollmentKinds.fingerprint) {
                    this.isFaceSelected = false;
                    this.renderFingerprint();
                }
            }

            this.flexEndButtons([
                {
                    buttonText: resourceStrings.HelloButtonText,
                    buttonType: "button",
                    isPrimaryButton: true,
                    autoFocus: (this.isLiteWhitePersonality || !this.isMultiChoice),
                    buttonClickHandler: (() => {
                        let faceInEffect = false;
                        let fingerprintInEffect = false;

                        if (this.isLiteWhitePersonality) {
                            faceInEffect = this.isMultiChoice ? this.isFaceSelected : this.enrollmentKinds.face;
                            fingerprintInEffect = this.isMultiChoice ? !this.isFaceSelected : this.enrollmentKinds.fingerprint;
                        } else {
                            faceInEffect = ((this.isMultiChoice && this.selectedItem().face) || (!this.isMultiChoice && this.enrollmentKinds.face));
                            fingerprintInEffect = ((this.isMultiChoice && this.selectedItem().fingerprint) || (!this.isMultiChoice && this.enrollmentKinds.fingerprint));
                        }

                        const enrollmentKind = {
                            face: faceInEffect,
                            fingerprint: fingerprintInEffect
                        };
                        this.onSetUpClick(enrollmentKind);
                    }),
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    })
                }
            ]);

            // LiteWhite personality uses css to style a secondary button (isPrimaryButton property == false) as a hyperlink.
            // Add "Skip for now" option to the flexEndButton array if this personality is set.
            // Otherwise, add to the flexStartHyperLinks array.
            if (this.isLiteWhitePersonality) {
                this.flexEndButtons.unshift({
                    buttonText: resourceStrings.HelloSkipLink,
                    buttonClickHandler: (() => {
                        this.onSkipClick();
                    })
                });
            }
            else {
                this.flexStartHyperLinks = [
                    {
                        hyperlinkText: resourceStrings.HelloSkipLink,
                        handler: () => {
                            this.onSkipClick();
                        }
                    }
                ];
            }

            this.pageDefaultAction = () => {
                if (this.isMultiChoice) {
                    this.flexEndButtons()[0].buttonClickHandler();
                }
            }
        }

        renderFace() {
            // If not LiteWhite personality (likely InclusiveBlue) , show gif instead of Lottie for face animation
            if (!this.isLiteWhitePersonality) {
                this.ariaLabel = resourceStrings.HelloFaceAnimationAltText;
                const faceAnimation = document.getElementById("helloFaceAnimation");
                faceAnimation.src = "/media/HelloFaceAnimation.gif";
                this.leadText(resourceStrings.HelloLeadTextFace);
            } else {
                this.subtitle(resourceStrings.HelloLeadTextFace);
                this.switchEnrollmentKindText(resourceStrings.HelloSwitchFaceToFingerprint);
                bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", "helloLottie.json");
            }
            this.title(resourceStrings.HelloTitleFace);
        }

        renderFingerprint() {
            // For fingerprint, only set values for animation control when showing the UI
            if (!this.isLiteWhitePersonality) {
                this.ariaLabel = resourceStrings.HelloFingerprintIconAriaLabel;
                this.leadText(resourceStrings.HelloLeadTextFingerprint);
            } else {
                this.subtitle(resourceStrings.HelloLeadTextFingerprint);
                this.switchEnrollmentKindText(resourceStrings.HelloSwitchFingerprintToFace);
                bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", "hellofingerprintLottie.json");
            }
            this.title(resourceStrings.HelloTitleFingerprint);
        }

        // This callback only applies in isMultiOption and isLiteWhitePersonality scenario
        onSwitchEnrollmentKindClick() {
            this.isFaceSelected = !this.isFaceSelected;

            if (this.isFaceSelected) {
                this.renderFace();
            } else {
                this.renderFingerprint();
            }

            return false;
        }

        onSetUpClick(enrollmentKind) {
            if (!this.processingFlag()) {
                this.processingFlag(true);

                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentShowingEnrollmentApp");

                bridge.invoke(this.isLiteWhitePersonality ? "CloudExperienceHost.getFrameViewBoundingRect" : "CloudExperienceHost.getBoundingClientRect").done((result) => {
                    const rect = {
                        height: result.height,
                        width: result.width,
                        x: result.x * window.devicePixelRatio,
                        y: result.y * window.devicePixelRatio
                    };

                    if (this.hideContentWhileBioAppIsLaunched) {
                        // Hide the content of this page to avoid undesired flashing after bio enrollment app
                        // finishes and this page shows up a split second before navigating to next page
                        this.contentContainerVisibility(false);
                    }
                    else {
                        // Hide all interactable button items from view, but maintain webapp view while bio enrollment app is showing
                        document.getElementById("helloFlexEndButtons").style.visibility = "hidden";
                    }

                    bridge.invoke("CloudExperienceHost.Hello.startHelloEnrollment", enrollmentKind, rect).done((enrollResult) => {
                        this.contentContainerVisibility(false);
                        window.removeEventListener("resize", HelloViewModel._onResize);

                          let enrollmentResult = JSON.parse(enrollResult);
                          if (enrollmentResult.completedWithError) {
                              bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentFailed");
                              bridge.fireEvent(constants.Events.done, constants.AppResult.cancel);
                          }
                          else if (enrollmentResult.completed) {
                              if (this.showConfirmationPage) {
                                this.updateToConfirmationPage();
                              }
                              else {
                                  bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentSuccess");
                                  bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                              }
                          }
                          else if (this.skipOnIncompleteEnrollment) {
                              bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentCanceled");
                              bridge.fireEvent(constants.Events.done, constants.AppResult.cancel);
                          }
                          else {
                              bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentCanceled");
                              bridge.invoke("CloudExperienceHost.undimChrome");
                              if (!this.hideContentWhileBioAppIsLaunched)
                              {
                                  document.getElementById("helloFlexEndButtons").style.visibility = "visible";
                              }

                              this.processingFlag(false);
                              // Show the content of this page if enrollment app cancels
                              this.contentContainerVisibility(true);
                              // Restore focus to the default focusable element as the flow is returning to this page
                              KoHelpers.setFocusOnAutofocusElement();
                          }
                    }, (error) => {
                        window.removeEventListener("resize", HelloViewModel._onResize);
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentFailed", core.GetJsonFromError(error));
                        bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
                    });

                    window.addEventListener("resize", HelloViewModel._onResize);
                    bridge.invoke("CloudExperienceHost.dimChrome");
                }, (error) => {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentSizingFailed", core.GetJsonFromError(error));
                    bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
                });
            }
        }

        onSkipClick() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentCanceled");
                bridge.fireEvent(constants.Events.done, constants.AppResult.cancel);
            }
        }

        onLearnMoreClick() {
            if (!this.processingFlag()) {
                bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "LearnMoreButtonClicked");
                this.processingFlag(true);
                this.learnMoreVisible(true);

                // Since the iframe isn't scrolled to the right anchor when loaded, we need to refresh the page for it to scroll to the Windows Hello section
                let learnMoreIFrame = document.getElementById("hello-learnmore-iframe");
                learnMoreIFrame.src = learnMoreIFrame.src;
                learnMoreIFrame.focus();
                this.processingFlag(false);
            }
        }

        onLearnMoreContinue() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "LearnMoreContinueButtonClicked");
                this.learnMoreVisible(false);
                KoHelpers.setFocusOnAutofocusElement();
            }
        }

        updateToConfirmationPage() {
            this.isConfirmationPageVisible(true);
            this.flexEndButtons([{
                buttonText: resourceStrings.NextButtonText,
                buttonType: "button",
                isPrimaryButton: true,
                autoFocus: true,
                buttonClickHandler: (() => {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentSuccess");
                    bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                })
            }]);
            document.getElementById("helloFlexEndButtons").style.visibility = "visible";
            document.getElementById("oobeHeader").classList.add("error-light");

            this.processingFlag(false);
            this.contentContainerVisibility(true);

            // Update the title and subtitle after restoring focus to ensure Narrator reads the updated text
            this.title(resourceStrings.AllSetText2);
            this.subtitle("");

            // Restore focus to the default focusable element as the flow is returning to this page
            KoHelpers.setFocusOnAutofocusElement();

        }

        static _onResize(param) {
            bridge.invoke(this.isLiteWhitePersonality ? "CloudExperienceHost.getFrameViewBoundingRect" : "CloudExperienceHost.getBoundingClientRect").done((result) => {
                try {
                    const rect = {
                        height: result.height,
                        width: result.width,
                        x: result.x * window.devicePixelRatio,
                        y: result.y * window.devicePixelRatio
                    };

                    bridge.invoke("CloudExperienceHost.Hello.updateWindowLocation", rect);
                }
                catch (error) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentResizingFailed", core.GetJsonFromError(error));
                }
            });
        }
    }

    return HelloViewModel;
});

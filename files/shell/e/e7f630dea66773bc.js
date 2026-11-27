//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'legacy/bridge', 'legacy/events', 'legacy/core', 'corejs/knockouthelpers'], (ko, bridge, constants, core, KoHelpers) => {
    class HelloNthViewModel {
        constructor(resourceStrings, enrollmentKinds) {
            this.resourceStrings = resourceStrings;
            this.enrollmentKinds = enrollmentKinds;
            this.processingFlag = ko.observable(false);
            this.contentContainerVisibility = ko.observable(true);
            this.flexStartHyperLinks = [];
            this.title = ko.observable("");
            this.leadText = ko.observable("");
            this.flexEndButtons = ko.observableArray([]);
            this.subtitle = ko.observable("");
            this.valueMessagingParagraphs = [];

            this.isMultiChoice = (this.enrollmentKinds.face && this.enrollmentKinds.fingerprint);
            this.isFaceSelected = true;
            this.switchEnrollmentKindText = ko.observable(resourceStrings.HelloSwitchFaceToFingerprint);
            this.isConfirmationPageVisible = ko.observable(false);

            //#region clean up this block during Feature_OobeHostPostMSAFlowMigration removal, and remove all usages of areIFrameFixesEnabled
            this.areIFrameFixesEnabled = false;

            // Initialize the URL regardless of feature flag to prevent undefined binding
            // Feature_OobeHostPostMSAFlowMigration cleanup - remove href,personalityQSParam, url, this.learnMoreWebSource   and keep content of if block
            let href = "https://go.microsoft.com/fwlink/p/?linkid=2169254";
            let personalityQSParam = "&profile=transparentLight";
            let url = href + personalityQSParam;
            this.learnMoreWebSource = url;

            bridge.invoke("CloudExperienceHost.FeatureStaging.tryGetIsFeatureEnabled", "OobeHostPostMSAFlowMigration").done((response) => {
                if ((response.result === 1) && (response.value === 1)) {
                    this.areIFrameFixesEnabled = true;
                    this.learnMoreWebSource = null;
                }
            });
            //#endregion

            this.valueMessagingParagraphs = [
                {
                    icon: "icon icon-shield-task",
                    heading: resourceStrings.HelloBodyTextParagraph1HeaderText,
                    content: resourceStrings.HelloBodyTextParagraph1ContentText,
                },
                {
                    icon: "icon icon-laptop-secure",
                    heading: resourceStrings.HelloBodyTextParagraph2HeaderText,
                    content: resourceStrings.HelloBodyTextParagraph2ContentText,
                },
                {
                    icon: "icon icon-dynamic-lock",
                    heading: resourceStrings.HelloBodyTextParagraph3HeaderText,
                    content: resourceStrings.HelloBodyTextParagraph3ContentText,
                },
            ]

            this.learnMoreVisible = ko.observable(false);
            this.learnMoreVisible.subscribe((newValue) => {
                if (newValue === false) {
                    // Reenable button interaction if we're not showing Learn More. On the Learn More page,
                    // buttons will be enabled after the iframe is shown
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
                // isMultiChoice
                // By default, render Hello Face as the selected one
                this.renderFace();
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
                    autoFocus: !this.isMultiChoice,
                    buttonClickHandler: (() => {
                        let faceInEffect = false;
                        let fingerprintInEffect = false;

                        faceInEffect = this.isMultiChoice ? this.isFaceSelected : this.enrollmentKinds.face;
                        fingerprintInEffect = this.isMultiChoice ? !this.isFaceSelected : this.enrollmentKinds.fingerprint;

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

            // We use css to style a secondary button (isPrimaryButton property == false) as a hyperlink.
            // Add "Skip for now" option to the flexEndButton array if this personality is set.
            this.flexEndButtons.unshift({
                buttonText: resourceStrings.HelloSkipLink,
                buttonClickHandler: (() => {
                    this.onSkipClick();
                })
            });

            this.pageDefaultAction = () => {
                if (this.isMultiChoice) {
                    this.flexEndButtons()[0].buttonClickHandler();
                }
            }
        }

        renderFace() {
            this.subtitle(resourceStrings.HelloLeadTextFace2);
            this.switchEnrollmentKindText(resourceStrings.HelloSwitchFaceToFingerprint);
            bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", "helloLottie.json");
            this.title(resourceStrings.HelloTitleFace2);
        }

        renderFingerprint() {
            this.subtitle(resourceStrings.HelloLeadTextFingerprint2);
            this.switchEnrollmentKindText(resourceStrings.HelloSwitchFingerprintToFace);
            bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", "hellofingerprintLottie.json");
            this.title(resourceStrings.HelloTitleFingerprint2);
        }

        // This callback only applies in isMultiOption scenario
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

                bridge.invoke("CloudExperienceHost.getFrameViewBoundingRect").done((result) => {
                    const rect = {
                        height: result.height,
                        width: result.width,
                        x: result.x * window.devicePixelRatio,
                        y: result.y * window.devicePixelRatio
                    };

                    // Hide all interactable button items from view, but maintain webapp view while bio enrollment app is showing
                    document.getElementById("helloFlexEndButtons").style.visibility = "hidden";

                    bridge.invoke("CloudExperienceHost.Hello.startHelloEnrollment", enrollmentKind, rect).done((enrollResult) => {
                        this.contentContainerVisibility(false);
                        window.removeEventListener("resize", HelloNthViewModel._onResize);

                          let enrollmentResult = JSON.parse(enrollResult);
                          if (enrollmentResult.completedWithError) {
                              bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentFailed");
                              bridge.fireEvent(constants.Events.done, constants.AppResult.cancel);
                          }
                          else if (enrollmentResult.completed) {
                                this.updateToConfirmationPage();
                          }
                          else {
                              bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentCanceled");
                              bridge.fireEvent(constants.Events.done, constants.AppResult.cancel);
                          }
                    }, (error) => {
                        window.removeEventListener("resize", HelloNthViewModel._onResize);
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentFailed", core.GetJsonFromError(error));
                        bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
                    });

                    window.addEventListener("resize", HelloNthViewModel._onResize);
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
                this.showLearnMore();
                this.processingFlag(false);
            }
        }

        showLearnMore() {
            let learnMoreIFrame = document.getElementById("hello-learnmore-iframe");

            // Feature_OobeHostPostMSAFlowMigration cleanup - remove if / else, and keep content of if block
            if (this.areIFrameFixesEnabled === true) {
                // Feature_OobeHostPostMSAFlowMigration cleanup - keep these lines
                let dirVal = document.documentElement.dir;
                let href = "https://go.microsoft.com/fwlink/p/?linkid=2169254"
                KoHelpers.showLearnMoreContent(learnMoreIFrame, href, dirVal, true, this.resourceStrings.HelloLearnMoreNavigationError, this.resourceStrings.HelloLearnMoreLinkText, "mainwindowshellomodule");
            } else {
                // Since the iframe isn't scrolled to the right anchor when loaded, we need to refresh the page for it to scroll to the Windows Hello section
                learnMoreIFrame.src = learnMoreIFrame.src;
                learnMoreIFrame.focus();
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
            this.title(resourceStrings.AllSetText2);
            this.subtitle("");
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

            // Restore focus to the default focusable element as the flow is returning to this page
            KoHelpers.setFocusOnAutofocusElement();
        }

        static _onResize(param) {
            bridge.invoke("CloudExperienceHost.getFrameViewBoundingRect").done((result) => {
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

    return HelloNthViewModel;
});

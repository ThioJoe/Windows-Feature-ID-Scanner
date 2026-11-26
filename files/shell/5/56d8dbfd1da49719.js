define(['lib/knockout', 'oobesettings-data', 'legacy/bridge', 'legacy/events', 'legacy/core', 'corejs/knockouthelpers'], (ko, oobeSettingsData, bridge, constants, core, KoHelpers) => {

    class PersonalDataExportViewModel {
        constructor(resources, isInternetAvailable, targetPersonality) {

            this.resources = resources;

            this.PageTitle = ko.observable(resources.PageTitle);
            this.PageSubtitle = ko.observable(resources.PageSubtitle);

            this.Paragraph1 = ko.observable(resources.Paragraph1);
            this.Paragraph2 = ko.observable(resources.Paragraph2);
            this.Paragraph3 = ko.observable(resources.Paragraph3);

            this.PrivacyLinkDisplayText = ko.observable(resources.PrivacyLinkDisplayText);

            this.learnMoreVisible = ko.observable(false);
            this.privacyVisible = ko.observable(false);
            this.pageVisible = ko.observable(true);

            this.processingFlag = ko.observable(false);
            this.disableControl = ko.pureComputed(() => {
                return this.processingFlag();
            });

            this.learnMoreButton = {
                buttonText: resources.LearnMoreButtonText,
                buttonClickHandler: () => {
                    this.onLearnMoreButtonClick();
                },
                disableControl: this.disableControl
            };

            this.onLearnMoreButtonClick = () => {
                if (!this.processingFlag()) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "MainPageLearnMoreButtonClicked");
                    this.processingFlag(true);
                    this.learnMoreVisible(true);
                    this.privacyVisible(false);
                    this.pageVisible(false);

                    let learnMoreIFrame = document.getElementById("learnMoreIFrame");
                    let doc = learnMoreIFrame.contentWindow.document;
                    oobeSettingsData.showLearnMoreContent(learnMoreIFrame, doc, resources.LearnMoreDataTransferUrl, document.documentElement.dir, isInternetAvailable, resources.NavigationError, targetPersonality);
                    this.processingFlag(false);
                    KoHelpers.setFocusOnAutofocusElement();
                }
            };

            this.nextButton = {
                isPrimaryButton: true,
                autoFocus: true,
                buttonText: resources.NextButtonText,
                buttonClickHandler: () => {
                    if (!this.processingFlag()) {
                        this.processingFlag(true);
                        bridge.fireEvent(CloudExperienceHost.Events.showProgressWhenPageIsBusy);

                        let response = true;

                        bridge.invoke("CloudExperienceHost.Telemetry.commitIntentPropertyBOOLAsync", "PersonalDataExport", "PDEShown", response).done(() => {
                            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ReportPDEShownSuccess", response);
                            bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                        }, (error) => {
                            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ReportPDEShownFailure", core.GetJsonFromError(error));
                            bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                        });
                    }
                },
                disableControl: ko.pureComputed(() => {
                    return this.processingFlag();
                })
            };

            this.mainPageFooterButtons = [
                this.learnMoreButton,
                this.nextButton
            ];

            this.learnMoreContinueButton = {
                buttonText: resources.ContinueButtonText,
                buttonType: "button",
                isPrimaryButton: true,
                autoFocus: false,
                disableControl: this.disableControl,
                buttonClickHandler: () => {
                    this.onLearnMoreContinue();
                }
            };

            this.onLearnMoreContinue = () => {
                if (!this.processingFlag()) {
                    this.processingFlag(true);
                    bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "LearnMoreContinueButtonClicked");
                    this.learnMoreVisible(false);
                    this.privacyVisible(false);
                    this.pageVisible(true);
                    this.processingFlag(false);
                    KoHelpers.setFocusOnAutofocusElement();
                }
            };

            this.learnMorePageFooterButtons = [
                this.learnMoreContinueButton
            ];

            this.onPrivacyLinkClick = () => {
                if (!this.processingFlag()) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "MainPagePrivacyLinkClicked");
                    this.processingFlag(true);
                    this.learnMoreVisible(false);
                    this.pageVisible(false);
                    this.privacyVisible(true);

                    let privacyIFrame = document.getElementById("privacyIFrame");
                    let doc = privacyIFrame.contentWindow.document;
                    oobeSettingsData.showLearnMoreContent(privacyIFrame, doc, resources.PrivacyStatementUrl, document.documentElement.dir, isInternetAvailable, resources.NavigationError, targetPersonality);
                    this.processingFlag(false);
					KoHelpers.setFocusOnAutofocusElement();
                }
            };

            this.privacyContinueButton = {
                buttonText: resources.ContinueButtonText,
                buttonType: "button",
                isPrimaryButton: true,
                autoFocus: false,
                disableControl: this.disableControl,
                buttonClickHandler: () => {
                    this.onPrivacyContinue();
                }
            };

            this.onPrivacyContinue = () => {
                if (!this.processingFlag()) {
                    this.processingFlag(true);
                    bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "PrivacyContinueButtonClicked");
                    this.learnMoreVisible(false);
                    this.privacyVisible(false);
                    this.pageVisible(true);
                    this.processingFlag(false);
                    KoHelpers.setFocusOnAutofocusElement();
                }
            };

            this.privacyPageFooterButtons = [
                this.privacyContinueButton
            ];

            this.onRefundLinkClick = () => {
                if (!this.processingFlag()) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "MainPageRefundLinkClicked");
                    this.processingFlag(true);
                    this.learnMoreVisible(false);
                    this.refundVisible(true);
                    this.pageVisible(false);
                    this.privacyVisible(false);

                    let refundIFrame = document.getElementById("refundIFrame");
                    let doc = refundIFrame.contentWindow.document;
                    oobeSettingsData.showLearnMoreContent(refundIFrame, doc, resources.RefundLinkUrl, document.documentElement.dir, isInternetAvailable, resources.NavigationError, targetPersonality);
                    this.processingFlag(false);
                    KoHelpers.setFocusOnAutofocusElement();
                }
            };

            this.refundContinueButton = {
                buttonText: resources.ContinueButtonText,
                buttonType: "button",
                isPrimaryButton: true,
                autoFocus: false,
                disableControl: this.disableControl,
                buttonClickHandler: () => {
                    this.onRefundContinue();
                }
            };

            this.onRefundContinue = () => {
                if (!this.processingFlag()) {
                    this.processingFlag(true);
                    bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "RefundContinueButtonClicked");
                    this.learnMoreVisible(false);
                    this.privacyVisible(false);
                    this.refundVisible(false);
                    this.pageVisible(true);
                    this.processingFlag(false);
                    KoHelpers.setFocusOnAutofocusElement();
                }
            };

            this.refundPageFooterButtons = [
                this.refundContinueButton
            ];
        }
    }
    return PersonalDataExportViewModel;
});

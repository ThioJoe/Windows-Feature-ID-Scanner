//
// Copyright (C) Microsoft. All rights reserved.
//
// ViewModel for the standalone AADC Learn More page. Fetches the required
// data-collection help content from the fwlink at render time via
// KoHelpers.showLearnMoreContent (which appends &profile=transparentLight,
// injects the OOBE iframe stylesheet, intercepts sub-links, and falls back to
// resourceStrings.NavigationError on failure -- see
// core/js/knockouthelpers.js::showLearnMoreContent).
//
// Continue and the host back chevron both funnel through onContinue and log the
// unprefixed "ContinueButtonClicked" event -- the legacy wire contract from
// oobeprivacysettings-aadc-vm.js (must not be renamed or prefixed).
define(['lib/knockout', 'legacy/bridge', 'legacy/events', 'corejs/knockouthelpers'], (ko, bridge, constants, KoHelpers) => {

    // Legacy parity: oobeprivacysettings-aadc-vm.js:106.
    const RequiredDataCollectionUrl = "https://go.microsoft.com/fwlink/?linkid=2162067";

    class LearnMoreAadcViewModel {
        constructor(resourceStrings, isInternetAvailable) {
            this.resourceStrings = resourceStrings;
            this.isInternetAvailable = isInternetAvailable;
            this.title = resourceStrings.LearnMoreTitle;

            this.processingFlag = ko.observable(false);
            this.flexEndButtons = [
                {
                    buttonText: resourceStrings.ContinueButtonText,
                    buttonType: "button",
                    isPrimaryButton: true,
                    autoFocus: true,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: (() => {
                        this.onContinue();
                    }),
                },
            ];
        }

        renderLearnMoreContent() {
            let iFrameElement = document.getElementById("learnMoreIFrame");
            if (iFrameElement) {
                let dirVal = document.documentElement.dir;
                KoHelpers.showLearnMoreContent(
                    iFrameElement,
                    RequiredDataCollectionUrl,
                    dirVal,
                    this.isInternetAvailable,
                    this.resourceStrings.NavigationError,
                    this.title);
            }
        }

        onContinue() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                // Legacy parity: oobeprivacysettings-aadc-vm.js:116 logs the unprefixed
                // "ContinueButtonClicked" via logUserInteractionEvent -- do not rename.
                bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "ContinueButtonClicked");
                bridge.fireEvent(constants.Events.done, constants.AppResult.success);
            }
        }
    }
    return LearnMoreAadcViewModel;
});

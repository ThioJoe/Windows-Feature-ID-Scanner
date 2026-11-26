//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'legacy/bridge', 'legacy/events', 'corejs/knockouthelpers'], (ko, bridge, constants, KoHelpers) => {

    class LearnMoreViewModel {
        constructor(resourceStrings, learnMoreContent, isInternetAvailable) {
            this.learnMoreContent = learnMoreContent;
            this.isInternetAvailable = isInternetAvailable;
            this.title = resourceStrings.HelloLearnMoreLinkText;

            this.processingFlag = ko.observable(false);
            this.flexEndButtons = [
                {
                    buttonText: resourceStrings.HelloContinueButtonText,
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
            if (iFrameElement && this.learnMoreContent) {
                let doc = iFrameElement.contentWindow.document;
                let dirVal = document.documentElement.dir;

                // Set the content of the iframe to the learn more content
                doc.body.innerHTML = this.learnMoreContent;

                // Set learn more scroll region title here for screen reader to read
                doc.body.title = this.title;

                // Styling on the local resource html content is managed by applying cssOverride
                let cssOverride = "/webapps/inclusiveOobe/css/light-iframe-content.css";
                let fileRef = doc.head.ownerDocument.createElement("link");
                fileRef.setAttribute("rel", "stylesheet");
                fileRef.setAttribute("href", cssOverride);
                doc.head.appendChild(fileRef);

                // Intercept links within the Learn More content
                let privacyLinks = doc.querySelectorAll("a");
                for (let i = 0; i < privacyLinks.length; i++) {
                    let link = privacyLinks[i];
                    link.onclick = (e) => {
                        KoHelpers.showLearnMoreContent(iFrameElement, e.target.href, dirVal, this.isInternetAvailable, this.title, this.title);
                        e.preventDefault();
                    };
                }
            }
        }

        onContinue() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "LearnMoreContinueButtonClicked");
                bridge.fireEvent(constants.Events.done, constants.AppResult.success);
            }
        }
    }
    return LearnMoreViewModel;
});

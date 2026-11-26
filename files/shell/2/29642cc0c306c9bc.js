//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'legacy/bridge', 'legacy/events', "legacy/core"], (ko, bridge, constants, core) => {
    const tagRetry = "retry";
    const tagSkip = "skip";

    class ErrorViewModel {
        constructor(resourceStrings, errorNode) {
            this.resourceStrings = resourceStrings;
            this.title = resourceStrings.ErrorTitle;
            this.skipButtonVisible = errorNode.failID ? true : false;
            this.subHeaderText = (this.skipButtonVisible) ? resourceStrings.ErrorRetryAndSkipText : resourceStrings.ErrorRetryOnlyText;
            this.cxidText = errorNode.cxid.toUpperCase();
            this.skipString = resourceStrings.ErrorButtonSkipText;

            this.processingFlag = ko.observable(false);
            this.flexEndButtons = [
                {
                    buttonText: this.skipString,
                    buttonType: "button",
                    isPrimaryButton: false,
                    isVisible: this.skipButtonVisible,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: (() => {
                        this.onSkip();
                    }),
                },
                {
                    buttonText: resourceStrings.ErrorButtonRetryText,
                    buttonType: "button",
                    isPrimaryButton: true,
                    autoFocus: true,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: (() => {
                        this.onRetry();
                    }),
                },
            ];
        }

        onRetry() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                bridge.fireEvent(constants.Events.retryApp, null);
            }
        }

        onSkip() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                bridge.fireEvent(constants.Events.skipApp, null);
            }
        }
    }
    return ErrorViewModel;
});

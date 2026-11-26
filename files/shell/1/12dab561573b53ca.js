//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'legacy/bridge', 'legacy/events', 'legacy/core'], (ko, bridge, constants, core) => {
    class ScoobeOutroViewModel {
        constructor(resourceStrings, targetPersonality) {
            this.resourceStrings = resourceStrings;

             this.isLiteWhitePersonality = ko.pureComputed(() => {
                return targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite;
            });
            
            if (this.isLiteWhitePersonality()) {
                this.title = resourceStrings.LightOutroTitle;
                this.subHeaderText = resourceStrings.LightOutroSubtitle;
            } else {
                this.title = resourceStrings.OutroTitle;
                this.subHeaderText = resourceStrings.OutroSubtitle;
                this.imageName = resourceStrings.OutroTitle;
            }

            this.processingFlag = ko.observable(false); 
            this.flexEndButtons = [
                {
                    buttonText: resourceStrings.CloseButtonText,
                    buttonType: "button",
                    isPrimaryButton: true,
                    isVisible: true,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: () => {
                        this.onCloseClick();
                    }
                }
            ];
        }

        onCloseClick() {
            bridge.fireEvent(constants.Events.done, constants.AppResult.exitCxhSuccess);
        }
    }
    return { ScoobeOutroViewModel };
});

//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'legacy/bridge', 'legacy/events', 'legacy/core'], (ko, bridge, constants, core) => {
    class NetworkDropoffHandlerViewModel {
        constructor(resourceStrings) {
            this.title = resourceStrings.Title;
            this.subHeaderText = resourceStrings.Subtitle;
            this.imageName = resourceStrings.Title;

            this.processingFlag = ko.observable(false);
            this.flexStartHyperLinks = [
                {
                    hyperlinkText: resourceStrings.NetworkHyperlinkText,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    handler: () => {
                        this.onNetworkClick();
                    }
                },
                {
                    hyperlinkText: resourceStrings.OptOutHyperlinkText,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    handler: () => {
                        this.onOptOutClick();
                    }
                }
            ];
            this.flexEndButtons = [
                {
                    buttonText: resourceStrings.CancelButtonText,
                    buttonType: "button",
                    autoFocus: false,
                    isPrimaryButton: false,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: () => {
                        this.onCancelClick();
                    }
                },
                {
                    buttonText: resourceStrings.RetryButtonText,
                    buttonType: "button",
                    autoFocus: true,
                    isPrimaryButton: true,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: () => {
                        this.onRetryClick();
                    }
                }
            ];
        }

        onRetryClick() {
            if (!this.processingFlag()) {
                bridge.fireEvent(constants.Events.done, constants.AppResult.success);
            }
        }

        onCancelClick() {
            if (!this.processingFlag()) {
                this.processingFlag(true);

                // Retrieve the resume offlineID
                bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "CancelButtonClicked");
                bridge.invoke("CloudExperienceHost.Storage.VolatileSharableData.getItem", "InPlaceResumeValues", "volatileResumeOfflineID").then(function (volatileResumeOfflineID) {
                    if (volatileResumeOfflineID) {
                        // Delete the volatile resume cxid and offlineID and fire Done with the offlineID
                        // Deletion is best-effort, so don't block firing the correct AppResult on the operation
                        bridge.invoke("CloudExperienceHost.Storage.VolatileSharableData.removeItem", "InPlaceResumeValues", "volatileResumeCxid");
                        bridge.invoke("CloudExperienceHost.Storage.VolatileSharableData.removeItem", "InPlaceResumeValues", "volatileResumeOfflineID");
                        bridge.fireEvent(constants.Events.done, volatileResumeOfflineID);
                    }
                    else {
                        // Fire error if no volatile resume offlineID exists
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "VolatileResumeOfflineIDNonexistent");
                        bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                    }
                }, function (err) {
                    // Fire error if we can't retrieve a volatile resume offlineID
                    if (err) {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "VolatileResumeOfflineIDRetrievalError", core.GetJsonFromError(err));
                    }
                    else {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "VolatileResumeOfflineIDRetrievalError");
                    }
                    bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                });
            }
        }

        onNetworkClick() {
            if (!this.processingFlag()) {
                // Open the network flyout
                bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "NetworkButtonClicked");
                Windows.System.Launcher.launchUriAsync(new Windows.Foundation.Uri("ms-availablenetworks:"));
            }
        }

        onOptOutClick() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                
                // Retrieve the resume offlineID
                bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "OptOutButtonClicked");
                bridge.invoke("CloudExperienceHost.Storage.VolatileSharableData.getItem", "InPlaceResumeValues", "volatileResumeOfflineID").then(function (volatileResumeOfflineID) {
                    if (volatileResumeOfflineID) {
                        // Next, write the opt-out value to VolatileSharableData
                        bridge.invoke("CloudExperienceHost.Storage.VolatileSharableData.addItem", "InPlaceResumeValues", "userOptedOut", true).then(function () {
                            // Delete the volatile resume cxid and offlineID and fire Done with the offlineID
                            // Deletion is best-effort, so don't block firing the correct AppResult on the operation
                            bridge.invoke("CloudExperienceHost.Storage.VolatileSharableData.removeItem", "InPlaceResumeValues", "volatileResumeCxid");
                            bridge.invoke("CloudExperienceHost.Storage.VolatileSharableData.removeItem", "InPlaceResumeValues", "volatileResumeOfflineID");
                            bridge.fireEvent(constants.Events.done, volatileResumeOfflineID);
                        }, function (err) {
                            // Fire error if committing the user's opt-out choice failed
                            if (err) {
                                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "UserOptedOutCommitError", core.GetJsonFromError(err));
                            }
                            else {
                                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "UserOptedOutCommitError");
                            }
                            bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                        });
                    }
                    else {
                        // Fire error if no volatile resume offlineId exists
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "VolatileResumeOfflineIDNonexistent");
                        bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                    }
                }, function (err) {
                    // Fire error if we can't retrieve a volatile resume offlineID
                    if (err) {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "VolatileResumeOfflineIDRetrievalError", core.GetJsonFromError(err));
                    }
                    else {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "VolatileResumeOfflineIDRetrievalError");
                    }
                    bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                });
            }
        }
    }
    return { NetworkDropoffHandlerViewModel };
});

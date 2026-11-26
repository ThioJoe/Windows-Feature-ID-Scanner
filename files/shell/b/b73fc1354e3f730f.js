define(['lib/knockout',
        'legacy/bridge',
        'legacy/events',
        'legacy/core',
        'legacy/appObjectFactory',
        'legacy/uiHelpers',
        'optional!sample/SampleImplementationCollection'],
        (ko, bridge, constants, core, appObjectFactory, legacy_uiHelpers, sampleCollection) => {
    class RegionViewModel {
        constructor(resourceStrings, regions, defaultregion, gestureManager) {
            this.gestureManager = gestureManager;
            this.items = regions;

            let gamepadEnabledObj = CloudExperienceHostAPI.FeatureStaging.tryGetIsFeatureEnabled("GamepadEnabledOobe");
            this.isGamepadEnabled = gamepadEnabledObj.result && gamepadEnabledObj.value;

            this.onFooterKeyDown = this.onFooterKeyDown.bind(this);

            let defaultRegionCode = defaultregion;
            let dataLayerDefaultRegion = CloudExperienceHostAPI.OobeRegionManagerStaticsCore.tryGetDefaultRegionIso2LetterCode();
            if (dataLayerDefaultRegion.succeeded) {
                defaultRegionCode = dataLayerDefaultRegion.value;
            }

            let defaultRegionIndex = this.items.findIndex((region) => (region.codeTwoLetter == defaultRegionCode));
            let defaultRegionObject = null;
            if (defaultRegionIndex > -1) {
                defaultRegionObject = this.items[defaultRegionIndex];
                this.items.splice(defaultRegionIndex, 1);
                this.items.unshift(defaultRegionObject);
            }
            this.selectedItem = ko.observable(defaultRegionObject);

            this.resourceStrings = resourceStrings;
            this.supportClickableTitle = true;

            this.questionType = {
                YESNOINITIAL: 0,                  // Initial speech with default region state
                YESNOCONFIRMREGION: 1,            // Confirmation of region state after the user has spoken the region
                OTHERCONSTRAINTS: 2,              // State in which user is expected to speak the region name
                FINAL: 3                          // State reached if Cortana is unable to select the region for the user and asks the user manually to select a region
            }

            this.title = ko.pureComputed(() => {
                return resourceStrings.RegionTitle.replace("%1", this.selectedItem().displayName);
            });

            this.listAccessibleName = resourceStrings.ListAccessibleName;
            this.stringWithRegionVoiceOver = resourceStrings.StringWithRegionVoiceOver.replace("%1", this.selectedItem().displayName);
            this.subtitle = resourceStrings.RegionLeadText;

            this.optinHotKey = true;

            this.pageDefaultAction = () => {
                this.onYesClick();
            }

            this.processingFlag = ko.observable(false);
            this.flexEndButtons = [
                {
                    buttonText: resourceStrings.YesButtonText,
                    buttonType: "button",
                    automationId: "OOBERegionYesButton",
                    isPrimaryButton: true,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: () => {
                        this.onYesClick();
                    }
                }
            ];

            this.regionConstraints = [];
            for (let i = 0; i < regions.length; i++) {
                let regionConstraint = new Windows.Media.SpeechRecognition.SpeechRecognitionListConstraint([legacy_uiHelpers.ReplaceHalfWidthCharsWithSpaces(regions[i].displayName)]);
                regionConstraint.tag = '#' + regions[i].codeTwoLetter;
                this.regionConstraints[i] = regionConstraint;
            }

            this.yesNoConstraints = new Array(CloudExperienceHostAPI.Speech.SpeechRecognitionKnownCommands.yes, CloudExperienceHostAPI.Speech.SpeechRecognitionKnownCommands.no);
        }

        speak(stringToSpeak, question) {
            let constraint = null;
            switch (question) {
                case this.questionType.YESNOINITIAL:
                case this.questionType.YESNOCONFIRMREGION:
                    constraint = this.yesNoConstraints;
                    break;
                case this.questionType.OTHERCONSTRAINTS:
                    constraint = this.regionConstraints;
                    break;
            };
            CloudExperienceHostAPI.Speech.SpeechRecognition.promptForCommandsAsync(stringToSpeak, constraint).done((result) => {
                if (result == null) {
                    if ((constraint != null) && !this.processingFlag()) {
                        this.speak(this.resourceStrings.FinalRegionVoiceOver, this.questionType.FINAL);
                    }
                }
                else if (!this.processingFlag()) {
                    switch (question) {
                        case this.questionType.YESNOINITIAL:
                        case this.questionType.YESNOCONFIRMREGION:
                            if (result.constraint.tag === CloudExperienceHostAPI.Speech.SpeechRecognitionKnownCommands.yes.tag) {
                                this.onYesClick();
                            }
                            else if (result.constraint.tag === CloudExperienceHostAPI.Speech.SpeechRecognitionKnownCommands.no.tag) {
                                if (question === this.questionType.YESNOINITIAL) {
                                    this.speak(this.resourceStrings.RegionToUseVoiceOver, this.questionType.OTHERCONSTRAINTS);
                                }
                                else {
                                    this.speak(this.resourceStrings.FinalRegionVoiceOver, this.questionType.FINAL);
                                }
                            }
                            break;
                        case this.questionType.OTHERCONSTRAINTS:
                            let itemToSelect = this.items.find((region) => '#' + region.codeTwoLetter == result.constraint.tag);
                            if (itemToSelect) {
                                this.selectedItem(itemToSelect);
                                this.speak(this.resourceStrings.ConfirmRegionVoiceOver.replace("%1", this.selectedItem().displayName), this.questionType.YESNOCONFIRMREGION);
                            }
                            else {
                                this.speak(this.resourceStrings.FinalRegionVoiceOver, this.questionType.FINAL);
                            }
                            break;
                    }
                }
            });
        }

        onYesClick() {
            if (!this.processingFlag()) {
                this.processingFlag(true);

                uiHelpers.PortableDeviceHelpers.unsubscribeToDeviceInsertion(this.gestureManager, bridge, core);

                try {
                    bridge.fireEvent(CloudExperienceHost.Events.showProgressWhenPageIsBusy);

                    let regionManager = appObjectFactory.getObjectFromString("CloudExperienceHostAPI.OobeRegionManagerStaticsCore");
                    let commitRegion = regionManager.commitRegionAsync(this.selectedItem().codeTwoLetter);
                    commitRegion.action.done(() => {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommitRegionSucceeded");
                        if (commitRegion.effects.rebootRequired) {
                            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommitRegionRebootRequired");
                            bridge.invoke("CloudExperienceHost.setRebootForOOBE");
                        }
                        bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                    }, (err) => {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommitRegionAsyncWorkFailure",
                            core.GetJsonFromError(err));
                        bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                    });
                }
                catch (err) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommitRegionFailure",
                       core.GetJsonFromError(err));
                    bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                }
            }
        }

        onFooterKeyDown(_, e) {
            let handled = false;

            if (this.isGamepadEnabled) {
                if (e.keyCode === WinJS.Utilities.Key.GamepadDPadUp || e.keyCode === WinJS.Utilities.Key.GamepadLeftThumbstickUp) {
                    let listview = document.querySelector("oobe-listview .list");
                    if (listview) {
                        listview.focus();
                        e.preventDefault();
                        handled = true;
                    }
                }
            }

            return !handled;
        }

        startVoiceOver() {
            this.speak(this.stringWithRegionVoiceOver, this.questionType.YESNOINITIAL);
        }

        subscribeToDeviceInsertion(gestureManager) {
            uiHelpers.PortableDeviceHelpers.subscribeToDeviceInsertion(gestureManager, bridge, core);
        }
    }
    return RegionViewModel;
});

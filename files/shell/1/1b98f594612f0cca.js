//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'oobeprivacysettings-data', 'legacy/bridge', 'legacy/events', 'legacy/core', 'corejs/knockouthelpers'], (ko, oobePrivacySettingsData, bridge, constants, core, KoHelpers) => {
    class OobePrivacySettingsAadcViewModel {
        constructor(resourceStrings, settingsEntryResourceStrings, isInternetAvailable) {
            bridge.addEventListener(constants.Events.backButtonClicked, this.handleBackNavigation.bind(this));
            this.resourceStrings = resourceStrings;
            this.isInternetAvailable = isInternetAvailable;
            this.settingsEntryResourceStrings = settingsEntryResourceStrings;
            this.viewName = ko.observable("defaults");
            this.learnMoreContent = " "; // Learn More content is purely server-side; initialize it to " " to create well-defined iframe content for keyboard focus and Narrator readout

            this.settingsObjects = this.getSettingsObjectsForAadcCommit();

            let titleTextStrings = {};
            let subTitleTextStrings = {};
            titleTextStrings["defaults"] = resourceStrings.Title;
            subTitleTextStrings["defaults"] = resourceStrings.Subtitle;
            titleTextStrings["learnmore"] = resourceStrings.LearnMoreTitle;
            subTitleTextStrings["learnmore"] = "";

            this.title = ko.pureComputed(() => {
                return titleTextStrings[this.viewName()];
            });
            this.subTitleText = ko.pureComputed(() => {
                return subTitleTextStrings[this.viewName()];
            });

            this.subtexts = [];
            this.subtexts.push({ header: resourceStrings.SubHeader1, bodyText: resourceStrings.SubText1 });
            this.subtexts.push({ header: resourceStrings.SubHeader2, bodyText: resourceStrings.SubText2 });

            this.processingFlag = ko.observable(false);
            let flexEndButtonSet = {};
            flexEndButtonSet["defaults"] = [
                {
                    buttonText: resourceStrings.LearnMoreButtonText,
                    buttonType: "button",
                    automationId: "LearnMoreButton",
                    isPrimaryButton: false,
                    autoFocus: false,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: () => {
                        this.onLearnMore();
                    }
                },
                {
                    buttonText: resourceStrings.NextButtonText,
                    buttonType: "button",
                    automationId: "NextButton",
                    isPrimaryButton: true,
                    autoFocus: true,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: () => {
                        this.onNext();
                    }
                }
            ];
            flexEndButtonSet["learnmore"] = [
                {
                    buttonText: resourceStrings.ContinueButtonText,
                    buttonType: "button",
                    automationId: "ContinueButton",
                    isPrimaryButton: true,
                    autoFocus: false,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: () => {
                        this.onLearnMoreContinue();
                    }
                }
            ];

            this.flexEndButtons = ko.pureComputed(() => {
                return flexEndButtonSet[this.viewName()];
            });
            this.learnMoreVisible = ko.pureComputed(() => {
                return (this.viewName() === "learnmore");
            });

            this.pageDefaultAction = () => {
                if (this.learnMoreVisible()) {
                    this.onLearnMoreContinue();
                } else {
                    this.onNext();
                }
            };
        }

        onLearnMore() {
            bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "LearnMoreButtonClicked");
            this.viewName("learnmore");
            bridge.invoke("CloudExperienceHost.setShowBackButton", true); // Ensure back button shows on Learn More page and that it will return to the main page
            this.showLearnMore();
            KoHelpers.setFocusOnAutofocusElement();
        }

        showLearnMore() {
            let learnMoreIFrame = document.getElementById("learnMoreIFrame");
            let doc = learnMoreIFrame.contentWindow.document;
            let dirVal = document.documentElement.dir;
            let requiredDataCollectionPage = "https://go.microsoft.com/fwlink/?linkid=2162067";
            oobePrivacySettingsData.showLearnMoreContent(learnMoreIFrame, doc, requiredDataCollectionPage, dirVal, this.isInternetAvailable, this.resourceStrings.NavigationError);
        }

        onNext() {
            bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "NextButtonClicked");
            oobePrivacySettingsData.commitSettings(this.settingsObjects, 4 /*PrivacyConsentPresentationVersion::NonInteractiveChildSettings*/);
        }

        onLearnMoreContinue() {
            bridge.invoke("CloudExperienceHost.Telemetry.logUserInteractionEvent", "ContinueButtonClicked");
            this.viewName("defaults");
            bridge.invoke("CloudExperienceHost.setShowBackButton", false); // Fall back to normal back button behavior
            KoHelpers.setFocusOnAutofocusElement();
        }

        handleBackNavigation() {
            if (this.learnMoreVisible()) {
                this.onLearnMoreContinue();
            }
        }

        getSettingsObjectsForAadcCommit() {
            let oobeScenario = (Windows.System.Profile.SystemSetupInfo.outOfBoxExperienceState != Windows.System.Profile.SystemOutOfBoxExperienceState.completed);

            let oobeSettingsGroups = oobePrivacySettingsData.getSettingsGroups(this.settingsEntryResourceStrings);
            let settingsObjects = [];
            for (let oobeSettingsGroup of oobeSettingsGroups) {
                let settingsInGroup = oobeSettingsGroup.settings;
                for (let setting of settingsInGroup) {
                    if (oobeScenario || oobePrivacySettingsData.shouldForceSettingOffForAadc(setting.settingKind)) {
                        // Force setting's value to false for AADC commit if we're in OOBE, or if the setting is per-user and therefore applicable in Nth scenario
                        setting.value = false;
                    }
                    settingsObjects.push(setting);
                }
            }
            return settingsObjects;
        }

    }
    return { OobePrivacySettingsAadcViewModel };
});

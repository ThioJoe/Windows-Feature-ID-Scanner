//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'legacy/bridge', 'legacy/events', 'legacy/core', 'corejs/knockouthelpers'], (ko, bridge, constants, core, KoHelpers) => {

    class UpdateSettingsViewModel {
        constructor(resources, targetPersonality) {
            bridge.addEventListener(constants.Events.backButtonClicked, this.handleBackNavigation.bind(this));
            this.resources = resources;
            this.contentSettings = this.getUpdateSettingsToggles();
            this.updateSettingsImage = "/webapps/inclusiveOobe/media/oobe-update-settings.svg";

            // observable to monitor page view change
            this.viewName = ko.observable("customize");

            let mainTitleTextStrings = {};
            let mainSubHeaderTextStrings = {};
            mainTitleTextStrings["customize"] = resources.UpdateSettingsTitle;
            mainSubHeaderTextStrings["customize"] = resources.UpdateSettingsSubtitle;
            mainTitleTextStrings["learnmore"] = resources.LearnMoreTitle;
            let innerHTML = "";
            this.initializeLearnMoreContent();

            this.title = ko.pureComputed(() => {
                return mainTitleTextStrings[this.viewName()];
            });
            this.subHeaderText = ko.pureComputed(() => {
                return mainSubHeaderTextStrings[this.viewName()];
            });

            this.processingFlag = ko.observable(false);
            let flexEndButtonSet = {};
            flexEndButtonSet["customize"] = [
                {
                    buttonText: resources.LearnMoreButtonText,
                    buttonType: "button",
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
                    buttonText: resources.NextButtonText,
                    buttonType: "button",
                    automationId: "OOBEUpdateSettingsAcceptButton",
                    isPrimaryButton: true,
                    autoFocus: true,
                    disableControl: ko.pureComputed(() => {
                        return this.processingFlag();
                    }),
                    buttonClickHandler: () => {
                        this.onSave();
                    }
                }
            ];
            flexEndButtonSet["learnmore"] = [
                {
                    buttonText: resources.ContinueButtonText,
                    buttonType: "button",
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

            this.customizeVisible = ko.pureComputed(() => {
                return (this.viewName() == "customize");
            });
            this.learnMoreVisible = ko.pureComputed(() => {
                return (this.viewName() == "learnmore");
            });

            this.pageDefaultAction = () => {
                if (this.customizeVisible()) {
                    this.onSave();
                }
                else if (this.learnMoreVisible()) {
                    this.onLearnMoreContinue();
                }
            };

            this.viewName.subscribe((newViewName) => {
                this.processingFlag(false);
            });

            let footerDescriptionTextSet = {};
            footerDescriptionTextSet["customize"] = resources.LearnMoreDescription;
            this.footerDescriptionText = ko.pureComputed(() => {
                return footerDescriptionTextSet[this.viewName()];
            });

            this.isLiteWhitePersonality = ko.pureComputed(() => {
                return targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite;
            });
        }

        initializeLearnMoreContent() {
            const cssOverride = "/webapps/inclusiveOobe/css/light-iframe-content.css";
            this.innerHTML = `<html><head><link href="${cssOverride}" rel="stylesheet"></head>`;
            this.innerHTML += "<b><p>" + this.resources.LearnMoreHeader1 + "</p></b>";
            this.innerHTML += "<p>" + this.resources.LearnMoreBody1 + "</p>";
            this.innerHTML += "<b><p>" + this.resources.LearnMoreHeader2 + "</p></b>";
            this.innerHTML += "<p>" + this.resources.LearnMoreBody2 + "</p>";
            this.innerHTML += "<b><p>" + this.resources.LearnMoreHeader3 + "</p></b>";
            this.innerHTML += "<p>" + this.resources.LearnMoreBody3 + "</p>";
            this.innerHTML += "</html>";
        }

        onLearnMore() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "UpdateSettings", "LearnMoreLink");
                this.viewName("learnmore");
                let iFrameElement = document.getElementById("learnMoreIFrame");
                let doc = iFrameElement.contentWindow.document;
                doc.body.innerHTML = this.innerHTML;
                bridge.invoke("CloudExperienceHost.setShowBackButton", true);
                this.processingFlag(false);
            }
        }

        handleBackNavigation() {
            if (this.learnMoreVisible()) {
                this.onLearnMoreContinue();
            }
        }

        onSave() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                try {
                    // Show the progress ring while committing async.
                    bridge.fireEvent(CloudExperienceHost.Events.showProgressWhenPageIsBusy);
                    this.contentSettings.toggleContent.forEach((setting) => {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommittedUpdateSetting_" + setting.name, setting.checkedValue());
                        if (setting.name === this.resources.OobeUpdateSettingsWindowsUpdateName) {
                            bridge.invoke("CloudExperienceHost.OobeUpdateSettings.setWindowsUpdateSetting", setting.checkedValue());
                        }
                        else {
                            bridge.invoke("CloudExperienceHost.OobeUpdateSettings.setAppStoreUpdateSetting", setting.checkedValue());
                        }
                    });
                    bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                }
                catch (err) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommitUpdateSettingsFailure", core.GetJsonFromError(err));
                    bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                }
            }
        }

        onLearnMoreContinue() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                this.viewName("customize");
                KoHelpers.setFocusOnAutofocusElement();
            }
        }

        getUpdateSettingsToggles() {
            return {
                toggleContent: 
                    [
                        {
                            labelOffText: this.resources.OobeUpdateSettingsOff,
                            labelOnText: this.resources.OobeUpdateSettingsOn,
                            checkedValue: ko.observable(true),
                            name: this.resources.OobeUpdateSettingsWindowsUpdateName,
                            descriptionOn: this.resources.OobeUpdateSettingsWindowsUpdateDescription,
                            descriptionOff: this.resources.OobeUpdateSettingsWindowsUpdateDescription,
                            titleText: this.resources.OobeUpdateSettingsWindowsUpdateDescription,
                            canonicalName: this.resources.OobeUpdateSettingsWindowsUpdateName,
                        },
                        {
                            labelOffText: this.resources.OobeUpdateSettingsOff,
                            labelOnText: this.resources.OobeUpdateSettingsOn,
                            checkedValue: ko.observable(true),
                            name: this.resources.OobeUpdateSettingsAppStoreUpdatesName,
                            descriptionOn: this.resources.OobeUpdateSettingsAppStoreUpdateDescription,
                            descriptionOff: this.resources.OobeUpdateSettingsAppStoreUpdateDescription,
                            titleText: this.resources.OobeUpdateSettingsAppStoreUpdateDescription,
                            canonicalName: this.resources.OobeUpdateSettingsAppStoreUpdatesName,
                        }
                    ]
            }
         }
    }
    return UpdateSettingsViewModel;
});

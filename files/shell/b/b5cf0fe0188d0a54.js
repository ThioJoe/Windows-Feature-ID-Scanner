//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'oobeprivacysettings-data', 'legacy/bridge', 'legacy/events', 'legacy/core', 'corejs/knockouthelpers'], (ko, oobePrivacySettingsData, bridge, constants, core, KoHelpers) => {
        class OobePrivacySettingsMultiPageViewModel {
            constructor(resources, settingsEntryResources, isInternetAvailable) {
                this.resources = resources;
                this.settingsEntryResources = settingsEntryResources;
                this.isInternetAvailable = isInternetAvailable;
                let settingsPagesAndSettings = this.getSettingsPages();
                this.settingsPageContent = settingsPagesAndSettings.settingsPageContent;
                this.settingsObjects = settingsPagesAndSettings.settingsObjects;

                // Set up member variables for the learn more page
                this.learnMoreVisible = ko.observable(false);
                this.learnMoreVisible.subscribe(() => {
                    this.setShowBackButton();
                });

               this.settingVisible = ko.pureComputed(() => {
                    return !this.learnMoreVisible();
                });

                this.learnMoreButtons = [
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

                this.onLearnMoreContinue = () => {
                    this.learnMoreVisible(false);
                };

                // Add event listener for back button
                bridge.addEventListener(constants.Events.backButtonClicked, this.handleBackNavigation.bind(this));

                this.processingFlag = ko.observable(false);
                this.disableControl = ko.pureComputed(() => {
                    return this.processingFlag();
                });

                this.currentPanelIndex = ko.observable(0);

                this.getPanelElement = (panelIndex) => {
                    return document.querySelector(".oobe-panel[data-panel-index='" + panelIndex + "']");
                };

                this.currentPanelElement = ko.pureComputed(() => {
                    return this.getPanelElement(this.currentPanelIndex());
                });

                this.pageDefaultAction = () => {
                    this.nextStep();
                };

                this.currentPanelIndex.subscribe((newStepIndex) => {
                    this.processingFlag(false);

                    let newStepPanel = document.querySelector(".oobe-panel[data-panel-index='" + newStepIndex + "']");
                    if (!newStepPanel) {
                        this.completePageFlow();
                    } else {
                        let page = ko.dataFor(this.currentPanelElement());
                        this.setShowBackButton();
                    }
                });

                this.pageFooterButtons = [
                    {
                        buttonText: resources.LearnMoreButtonText,
                        buttonClickHandler: () => {
                            this.onLearnMoreButtonClick();
                        },
                        disableControl: this.disableControl
                    },
                    {
                        buttonText: resources.NextButtonText,
                        buttonClickHandler: () => {
                            this.nextStep();
                        },
                        disableControl: ko.pureComputed(() => {
                            let currentPanelIndexValue = this.currentPanelIndex();
                            return (this.settingsPageContent[currentPanelIndexValue] === undefined) ||
                                   (this.settingsPageContent[currentPanelIndexValue].selectedItem() === undefined) ||
                                   this.processingFlag();
                        }),
                        isPrimaryButton: true
                    }
                ];

                // One of the component redirections loses the object context for invoking this. For now use an arrow function to work around this.
                this.nextStep = () => {
                    if (!this.processingFlag()) {
                        this.processingFlag(true);
                        this.currentPanelIndex(this.currentPanelIndex() + 1);
                    }
                };

                this.firstPanelRender = () => {
                    let item = ko.dataFor(this.currentPanelElement());
                };

                this.completePageFlow = () => {
                    oobePrivacySettingsData.commitSettings(this.settingsObjects, 3 /*PrivacyConsentPresentationVersion::OneSettingPerPageTwoItemListView*/);
                };

                this.onLearnMoreButtonClick = () => {
                    this.learnMoreVisible(true);
                    this.updateLearnMore();
                    this.setShowBackButton();
                };
            }

            updateLearnMore() {
                let learnMoreIFrame = document.getElementById("learnMoreIFrame");
                let dirVal = document.documentElement.dir;
                let currentItem = this.settingsObjects[this.currentPanelIndex()];
                oobePrivacySettingsData.updateLearnMoreContentForRender(learnMoreIFrame, dirVal, this.isInternetAvailable, this.resources.NavigationError, this.resources.LearnMoreTitle, currentItem);
            }

            handleBackNavigation() {
                // Since the back button in Frame is removed asynchronously, multiple back navigations may arrive
                // during transitions within the webapp panes.
                // Therefore also cap the panel index decrement at zero.
                if (this.settingVisible() && !this.processingFlag() && (this.currentPanelIndex() > 0)) {
                    this.processingFlag(true);
                    this.currentPanelIndex(this.currentPanelIndex() - 1);
                } else if (this.learnMoreVisible()) {
                    this.learnMoreVisible(false);
                }
            }

            setShowBackButton() {
                if (this.learnMoreVisible()) {
                    bridge.invoke("CloudExperienceHost.setShowBackButton", true);
                } else if (this.currentPanelIndex() > 0) {
                    // get result of bridge call to determine if back button should be shown
                    let result = bridge.invoke("CloudExperienceHost.setShowBackButton", true);
                } else {
                    bridge.invoke("CloudExperienceHost.setShowBackButton", false);
                }
            }

            // Converts the underlying settings objects into a format consumable by the multi-page variant of oobe settings
            getSettingsPages() {
                //let platform = CloudExperienceHostAPI.Environment.platform;
                let oobeSettingsGroups = oobePrivacySettingsData.getSettingsGroups(this.settingsEntryResources);
                let settingsObjects = [];
                let settingsPageContent = [];
                for (let oobeSettingsGroup of oobeSettingsGroups) {
                    let settingsInGroup = oobeSettingsGroup.settings;

                    for (let setting of settingsInGroup) {
                    
                    settingsObjects.push(setting);
                        let page = {
                            title: setting.title,
                            items: [
                                {
                                    value: true,
                                    valueText: setting.value2OnLabel,
                                    icon: setting.onGlyph,
                                    descriptionText: setting.description2On
                                },
                                {
                                    value: false,
                                    icon: setting.offGlyph,
                                    valueText: setting.value2OffLabel,
                                    descriptionText: setting.description2Off
                                }
                            ],
                            selectedItem: ko.observable()
                        };
                        page.selectedItem.subscribe((item) => {
                            setting.value = item.value;
                        });
                        
                        //add the page to the list
                        settingsPageContent.push(page);
                    }
                }

                return {
                    settingsPageContent: settingsPageContent,
                    settingsObjects: settingsObjects
                };
            }
        }
        return OobePrivacySettingsMultiPageViewModel;
});

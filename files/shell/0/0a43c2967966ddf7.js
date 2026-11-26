-//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'oobeprivacysettings-data', 'legacy/bridge', 'legacy/events', 'legacy/core', 'corejs/knockouthelpers'], (ko, oobePrivacySettingsData, bridge, constants, core, KoHelpers) => {
    class OobePrivacySettingsViewModel {
        constructor(resources, settingsEntryResources, isInternetAvailable) {
            bridge.addEventListener(constants.Events.backButtonClicked, this.handleBackNavigation.bind(this));
            this.resources = resources;
            this.settingsEntryResources = settingsEntryResources;
            this.isInternetAvailable = isInternetAvailable;
            let oobeSettingsToggles = this.getSettingsToggles();
            this.contentSettings = oobeSettingsToggles.settingsData;
            this.settingsObjects = oobeSettingsToggles.settingsObjects;        
            this.learnMoreContent = oobePrivacySettingsData.getLearnMoreContent();
            this.scrolledToTheBottom = true;
            this.firstUpdateForScrollState = true;
            this.scrollViewEle = null;
            this.scrollDuration = 666;

            // observable to monitor page view change
            this.viewName = ko.observable("customize");

            let mainTitleTextStrings = {};
            let mainSubHeaderTextStrings = {};
            mainTitleTextStrings["customize"] = resources.SettingsTitle;
            mainSubHeaderTextStrings["customize"] = resources.SettingsSubtitle;
            mainTitleTextStrings["learnmore"] = resources.LearnMoreTitle;

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
                    automationId: "OobeSettingsLearnMoreButton",
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
                    buttonText: resources.AcceptButtonText,
                    buttonType: "button",
                    automationId: "OobeSettingsAcceptButton",
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
                    automationId: "OobeSettingsContinueButton",
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
                return (this.viewName() === "customize");
            });

            this.learnMoreVisible = ko.pureComputed(() => {
               return (this.viewName() === "learnmore");
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

            this.initScrollState();
        }

        initScrollState() {
            this.scrolledToTheBottom = true;
            this.firstUpdateForScrollState = true;
            this.scrollViewEle = document.querySelector('#scrollRegion');
            if (this.scrollViewEle) {
                this.scrollViewEle.addEventListener("scroll", this.updateForScrollState.bind(this));
            }

            document.addEventListener("keyup", this.tabKeyUpHandler.bind(this));
        }

        onToggleChange() {
        }

        onSave() {
            if (!this.processingFlag()) {
                this.processingFlag(true);

                if (!this.scrolledToTheBottom) {
                    if (this.scrollViewEle) {
                        this.scrollTo(this.scrollViewEle, this.scrollViewEle.scrollTop + this.scrollViewEle.offsetHeight, true /* autoFocus */);
                    }
                }
                else {
                    oobePrivacySettingsData.commitSettings(this.settingsObjects, 2 /*PrivacyConsentPresentationVersion::AllSettingsSinglePageTwoColumn*/);
                }
            }
        }

        onLearnMore() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Settings", "LearnMoreLink");
                this.viewName("learnmore");
                bridge.invoke("CloudExperienceHost.setShowBackButton", true); // Ensure back button shows on Learn More page and that it will return to the main page
                this.onAfterViewNameUpdated();
                KoHelpers.setFocusOnAutofocusElement();
            }
        }

        onAfterViewNameUpdated() {
            let learnMoreIFrame = document.getElementById("learnMoreIFrame");
            let doc = learnMoreIFrame.contentWindow.document;
            oobePrivacySettingsData.updateLearnMoreContentForRender(learnMoreIFrame, doc, document.documentElement.dir, this.isInternetAvailable, this.resources.NavigationError, this.resources.LearnMoreTitle);
        }

        updateForScrollState() {
            if (this.firstUpdateForScrollState || !this.scrolledToTheBottom) {
                let lastEle = document.querySelector('#lastElementInToggleList');
                if (lastEle) {
                    this.scrolledToTheBottom = this.isScrolledIntoView(lastEle);
                    let btnTextCurr = this.scrolledToTheBottom ? this.resources.AcceptButtonText : this.resources.NextButtonText;
                    let btnEle = document.querySelector('#OobeSettingsAcceptButton');
                    if (btnEle && (btnTextCurr !== btnEle.innerHTML)) {
                        btnEle.innerHTML = btnTextCurr;
                        if (!this.scrolledToTheBottom) {
                            // Override the visible button label when we need to explain an unusual effect
                            btnEle.setAttribute("aria-label", this.resources.NextButtonAccLabel);
                        }
                        else {
                            btnEle.setAttribute("aria-label", this.resources.AcceptButtonAccLabel);
                        }
                    }
                }
                this.firstUpdateForScrollState = false;
            }
            this.enableToggleAria();
        }

        enableToggleAria() {
            if (this.scrollViewEle) {
                this.scrollViewEle.removeAttribute("aria-hidden");
            }
        }

        tabKeyUpHandler(e) {
            if (!this.scrolledToTheBottom && (e.keyCode === WinJS.Utilities.Key.tab)) {
                let focused = document.activeElement;
                if (focused && focused.winControl && focused.winControl.isLastInAGroup) {
                    this.scrollTo(this.scrollViewEle, this.scrollViewEle.scrollTop + this.scrollViewEle.offsetHeight, false /* autoFocus */);
                }
            }
        }

        isScrolledIntoView(el) {
            let visible = true;
            if (this.scrollViewEle) {
                let rect = el.getBoundingClientRect();
                visible = (rect.top >= 0) && (rect.bottom <= this.scrollViewEle.offsetTop + this.scrollViewEle.offsetHeight);
            }
            return visible;
        }

        scrollTo(element, to, autoFocus) {
            let start = element.scrollTop,
                change = to - start,
                currentTime = 0,
                increment = 20;

            let animateScroll = function () {
                currentTime += increment;
                let val = this.easeInOutQuad(currentTime, start, change, this.scrollDuration);
                element.scrollTop = val;
                if (currentTime < this.scrollDuration) {
                    setTimeout(animateScroll, increment);
                }
                else {
                    this.processingFlag(false);
                    if (autoFocus) {
                        KoHelpers.setFocusOnAutofocusElement();
                    }
                }
                this.updateForScrollState();
            }.bind(this);
            animateScroll();
        }

        //t = current time
        //b = start value
        //c = change in value
        //d = duration
        easeInOutQuad(t, b, c, d) {
            t /= d / 2;
            if (t < 1) return c / 2 * t * t + b;
            t--;
            return -c / 2 * (t * (t - 2) - 1) + b;
        }

        onLearnMoreContinue() {
            if (!this.processingFlag()) {
                this.processingFlag(true);
                this.viewName("customize");
                bridge.invoke("CloudExperienceHost.setShowBackButton", false); // Fall back to normal back button behavior
                this.initScrollState();
                this.updateForScrollState();
                KoHelpers.setFocusOnAutofocusElement();
            }
        }

        handleBackNavigation() {
            if (this.learnMoreVisible()) {
                this.onLearnMoreContinue();
            }
        }

        getSettingsToggles() {
            //initialize the settingsData object
            let settingsData = [];
            let settingsObjects = [];
            let oobeSettingsGroups = oobePrivacySettingsData.getSettingsGroups(this.settingsEntryResources);

            for (let oobeSettingsGroup of oobeSettingsGroups) {
                let settingsGroupModel = {};
                settingsGroupModel.contentHeader = oobeSettingsGroup.contentHeader;
                settingsGroupModel.description = oobeSettingsGroup.description;

                let toggles = [];
                let settingsInGroup = oobeSettingsGroup.settings;
                let settingsLen = settingsInGroup.length;
                for (let index = 0; index < settingsLen; index++) {
                    let setting = settingsInGroup[index];
                    settingsObjects.push(setting);
                    let toggle = {
                        labelOffText: setting.valueOffLabel,
                        labelOnText: setting.valueOnLabel,
                        checkedValue: ko.observable(setting.value),
                        isLastInAGroupValue: (index === (settingsLen - 1)) ? true : false,
                        name: setting.name,
                        descriptionOn: setting.descriptionOn,
                        descriptionOff: setting.descriptionOff,
                        titleText: ko.observable(setting.value ? setting.descriptionOn : setting.descriptionOff)
                    };
                    toggle.checkedValue.subscribe(function (newValue) {
                        setting.value = newValue;
                        toggle.titleText(newValue ? toggle.descriptionOn : toggle.descriptionOff);
                    });
                    toggles.push(toggle);
                }
                settingsGroupModel.toggleContent = toggles;
                settingsData.push(settingsGroupModel);
            }
            return {
                settingsData: settingsData,
                settingsObjects: settingsObjects
            };
        }
    }
    return OobePrivacySettingsViewModel;
});

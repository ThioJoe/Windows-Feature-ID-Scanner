//
// Copyright (C) Microsoft. All rights reserved.
//
define(["lib/knockout", 'legacy/bridge', 'legacy/events', 'legacy/core', 'corejs/knockouthelpers'], (ko, bridge, constants, core, KoHelpers) => {
    class OobePrivacySettingsData {
        commitSettings(settings, privacyConsentPresentationVersion) {
            try {
                // Show the progress ring while committing async.
                bridge.fireEvent(CloudExperienceHost.Events.showProgressWhenPageIsBusy);

                let userChoicesAndPresentationVersion = [];

                let userChoices = [];
                for (let setting of settings) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", this.privacySettingKindToString(setting.settingKind), setting.value);
                    userChoices.push(setting.settingKind);
                    userChoices.push(setting.value);
                }

                userChoicesAndPresentationVersion.push(userChoices);
                userChoicesAndPresentationVersion.push(privacyConsentPresentationVersion);

                bridge.invoke("CloudExperienceHost.Privacy.commitSettingsAsync", userChoicesAndPresentationVersion).then(() => {
                    bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                }, (err) => {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommitSettingsAsyncWorkerFailure", core.GetJsonFromError(err));
                    bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                });
            }
            catch (err) {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommitSettingsFailure", core.GetJsonFromError(err));
                bridge.fireEvent(constants.Events.done, constants.AppResult.error);
            }
        }

        initializePrivacySettingsAsync() {
            bridge.invoke("CloudExperienceHost.Privacy.getUserSetupPrivacySettingKindEnumValueAsync").then((privacySettingKind) => {
                this.privacySettingKind = Object.freeze(privacySettingKind);
            });

            bridge.invoke("CloudExperienceHost.Privacy.getInitialUserSettingsAsync").then((initialUserSettings) => {
                this.initialUserSettings = initialUserSettings;
            });

            bridge.invoke("CloudExperienceHost.Privacy.getLearnMorePlainTextAsync").then((learnMoreContent) => {
                this.learnMoreContent = learnMoreContent;
            });
        }

        privacySettingKindToString(privacySettingKind) {
            // These strings map to the canonical names defined in
            // %SDXROOT%\onecoreuap\shell\cloudexperiencehost\onecore\inc\oobesettingsutil.h
            // and are used for compatibility with existing telemetry
            switch (privacySettingKind) {
                case this.privacySettingKind.Location:
                    return 'Location';
                case this.privacySettingKind.InputDiagnostics:
                    return 'InputDiagnostics';
                case this.privacySettingKind.OptionalDiagnostics:
                    return 'Telemetry';
                case this.privacySettingKind.PersonalizedOffers:
                    return 'PersonalizedOffers';
                case this.privacySettingKind.PersonalizedOffersWindowsDiagnostics:
                case this.privacySettingKind.TailoredExperiences: // When Feature_OobePersonalizedOffers is fully enabled, TailoredExperiences should be removed
                    return 'Tailored';
                case this.privacySettingKind.FindMyDevice:
                    return 'FindMyDevice';
                case this.privacySettingKind.HumanPresence:
                    return 'HumanPresence';
                default:
                    return 'Unknown';
            }
        }

        shouldForceSettingOffForAadc(settingKind) {
            // Settings that should be forced off for AADC
            // Other settings should be re-committed with their existing values
            switch (settingKind) {
                case this.privacySettingKind.Location:
                case this.privacySettingKind.InputDiagnostics:
                case this.privacySettingKind.PersonalizedOffers:
                case this.privacySettingKind.PersonalizedOffersWindowsDiagnostics:
                case this.privacySettingKind.TailoredExperiences: // When Feature_OobePersonalizedOffers is fully enabled, TailoredExperiences should be removed
                    return true;
                default:
                    return false;
            }
        }

        // Create settings group
        getSettingsGroups(settingsEntryResources) {
            let settingsGroups = [
                {
                    contentHeader: settingsEntryResources.OobeSettingsGroupName,
                    description: settingsEntryResources.OobeSettingsGroupDescription,
                    settings: this.getSettings(settingsEntryResources)
                }
            ];
            return settingsGroups;
        }

        getSettings(settingsEntryResources) {
            let locationSetting = {
                settingKind: this.privacySettingKind.Location,
                name: settingsEntryResources.OobeSettingsLocationName,
                title: settingsEntryResources.OobeSettingsLocationTitle,
                descriptionOn: settingsEntryResources.OobeSettingsLocationDescOn,
                descriptionOff: settingsEntryResources.OobeSettingsLocationDescOff,
                description2On: settingsEntryResources.OobeSettingsLocationDesc2On,
                description2Off: settingsEntryResources.OobeSettingsLocationDesc2Off,
                onGlyph: settingsEntryResources.OobeSettingsLocationGlyphOn,
                offGlyph: settingsEntryResources.OobeSettingsLocationGlyphOff,
                valueOnLabel: settingsEntryResources.OobeSettingsOn,
                valueOffLabel: settingsEntryResources.OobeSettingsOff,
                value2OnLabel: settingsEntryResources.OobeSettingsOn,
                value2OffLabel: settingsEntryResources.OobeSettingsOff,
                value: false
            };

            let inputDiagnosticSetting = {
                settingKind: this.privacySettingKind.InputDiagnostics,
                name: settingsEntryResources.OobeSettingsInputDiagnosticName,
                title: settingsEntryResources.OobeSettingsInputDiagnosticTitle,
                descriptionOn: settingsEntryResources.OobeSettingsInputDiagnosticDescOn,
                descriptionOff: settingsEntryResources.OobeSettingsInputDiagnosticDescOff,
                description2On: settingsEntryResources.OobeSettingsInputDiagnosticDesc2On,
                description2Off: settingsEntryResources.OobeSettingsInputDiagnosticDesc2Off,
                onGlyph: settingsEntryResources.OobeSettingsInputDiagnosticGlyphOn,
                offGlyph: settingsEntryResources.OobeSettingsInputDiagnosticGlyphOff,
                valueOnLabel: settingsEntryResources.OobeSettingsOn,
                valueOffLabel: settingsEntryResources.OobeSettingsOff,
                value2OnLabel: settingsEntryResources.OobeSettingsOn,
                value2OffLabel: settingsEntryResources.OobeSettingsOff,
                value: false
            };

            let telemetrySetting = {
                settingKind: this.privacySettingKind.OptionalDiagnostics,
                name: settingsEntryResources.OobeSettingsTelemetryName,
                title: settingsEntryResources.OobeSettingsTelemetryTitle,
                descriptionOn: settingsEntryResources.OobeSettingsTelemetryDescOn,
                descriptionOff: settingsEntryResources.OobeSettingsTelemetryDescOff,
                description2On: settingsEntryResources.OobeSettingsTelemetryDesc2OnV2,
                description2Off: settingsEntryResources.OobeSettingsTelemetryDesc2Off,
                onGlyph: settingsEntryResources.OobeSettingsTelemetryGlyphOn,
                offGlyph: settingsEntryResources.OobeSettingsTelemetryGlyphOff,
                valueOnLabel: settingsEntryResources.OobeSettingsLabelFull,
                valueOffLabel: settingsEntryResources.OobeSettingsLabelBasic,
                value2OnLabel: settingsEntryResources.OobeSettingsLabelFull,
                value2OffLabel: settingsEntryResources.OobeSettingsLabelBasic,
                value: false
            };

            let personalizedOffersSetting = {
                settingKind: this.privacySettingKind.PersonalizedOffers,
                name: settingsEntryResources.OobeSettingsPersonalizedOffersName,
                title: settingsEntryResources.OobeSettingsPersonalizedOffersTitle,
                descriptionOn: settingsEntryResources.OobeSettingsPersonalizedOffersDescOn,
                descriptionOff: settingsEntryResources.OobeSettingsPersonalizedOffersDescOff,
                description2On: settingsEntryResources.OobeSettingsPersonalizedOffersDesc2On,
                description2Off: settingsEntryResources.OobeSettingsPersonalizedOffersDesc2Off,
                onGlyph: settingsEntryResources.OobeSettingsPersonalizedOffersGlyphOn,
                offGlyph: settingsEntryResources.OobeSettingsPersonalizedOffersGlyphOff,
                valueOnLabel: settingsEntryResources.OobeSettingsOn,
                valueOffLabel: settingsEntryResources.OobeSettingsOff,
                value2OnLabel: settingsEntryResources.OobeSettingsOn,
                value2OffLabel: settingsEntryResources.OobeSettingsOff,
                value: false
            };

            let personalizedOffersWindowsDiagnosticsSetting = {
                settingKind: this.privacySettingKind.PersonalizedOffersWindowsDiagnostics,
                name: settingsEntryResources.OobeSettingsPersonalizedOffersName,
                title: settingsEntryResources.OobeSettingsPersonalizedOffersTitle,
                descriptionOn: settingsEntryResources.OobeSettingsTailoredDescOn,
                descriptionOff: settingsEntryResources.OobeSettingsTailoredDescOff,
                description2On: settingsEntryResources.OobeSettingsTailoredDesc2On,
                description2Off: settingsEntryResources.OobeSettingsTailoredDesc2Off,
                onGlyph: settingsEntryResources.OobeSettingsPersonalizedOffersGlyphOn,
                offGlyph: settingsEntryResources.OobeSettingsPersonalizedOffersGlyphOff,
                valueOnLabel: settingsEntryResources.OobeSettingsOn,
                valueOffLabel: settingsEntryResources.OobeSettingsOff,
                value2OnLabel: settingsEntryResources.OobeSettingsOn,
                value2OffLabel: settingsEntryResources.OobeSettingsOff,
                value: false
            };

            // When Feature_OobePersonalizedOffers is fully enabled, the Tailored Experiences setting should be removed
            // and the following strings in oobePrivacySettingsEntry.resjson should be cleaned up as well:
            // OobeSettingsTailoredName, OobeSettingsTailoredTitle, OobeSettingsTailoredDescOnOld, OobeSettingsTailoredDescOffOld,
            // OobeSettingsTailoredDesc2OnOld, OobeSettingsTailoredDesc2OffOld, OobeSettingsTailoredGlyphOn, OobeSettingsTailoredGlyphOff

            let tailoredExperiencesSetting = {
                settingKind: this.privacySettingKind.TailoredExperiences,
                name: settingsEntryResources.OobeSettingsTailoredName,
                title: settingsEntryResources.OobeSettingsTailoredTitle,
                descriptionOn: settingsEntryResources.OobeSettingsTailoredDescOnOld,
                descriptionOff: settingsEntryResources.OobeSettingsTailoredDescOffOld,
                description2On: settingsEntryResources.OobeSettingsTailoredDesc2OnOld,
                description2Off: settingsEntryResources.OobeSettingsTailoredDesc2OffOld,
                onGlyph: settingsEntryResources.OobeSettingsTailoredGlyphOn,
                offGlyph: settingsEntryResources.OobeSettingsTailoredGlyphOff,
                valueOnLabel: settingsEntryResources.OobeSettingsOn,
                valueOffLabel: settingsEntryResources.OobeSettingsOff,
                value2OnLabel: settingsEntryResources.OobeSettingsOn,
                value2OffLabel: settingsEntryResources.OobeSettingsOff,
                value: false
            };

            let findMyDeviceSetting = {
                settingKind: this.privacySettingKind.FindMyDevice,
                name: settingsEntryResources.OobeSettingsFindMyDeviceName,
                title: settingsEntryResources.OobeSettingsFindMyDeviceTitle,
                descriptionOn: settingsEntryResources.OobeSettingsFindMyDeviceDescOn,
                descriptionOff: settingsEntryResources.OobeSettingsFindMyDeviceDescOff,
                description2On: settingsEntryResources.OobeSettingsFindMyDeviceDesc2On,
                description2Off: settingsEntryResources.OobeSettingsFindMyDeviceDesc2Off,
                onGlyph: settingsEntryResources.OobeSettingsFindMyDeviceGlyphOn,
                offGlyph: settingsEntryResources.OobeSettingsFindMyDeviceGlyphOff,
                valueOnLabel: settingsEntryResources.OobeSettingsOn,
                valueOffLabel: settingsEntryResources.OobeSettingsOff,
                value2OnLabel: settingsEntryResources.OobeSettingsOn,
                value2OffLabel: settingsEntryResources.OobeSettingsOff,
                value: false
            };

            let humanPresenceSetting = {
                settingKind: this.privacySettingKind.HumanPresence,
                name: settingsEntryResources.OobeSettingsHumanPresenceName,
                title: settingsEntryResources.OobeSettingsHumanPresenceTitle,
                descriptionOn: settingsEntryResources.OobeSettingsHumanPresenceDescOn,
                descriptionOff: settingsEntryResources.OobeSettingsHumanPresenceDescOff,
                description2On: settingsEntryResources.OobeSettingsHumanPresenceDescOn,
                description2Off: settingsEntryResources.OobeSettingsHumanPresenceDescOff,
                onGlyph: settingsEntryResources.OobeSettingsHumanPresenceGlyphOn,
                offGlyph: settingsEntryResources.OobeSettingsHumanPresenceGlyphOff,
                valueOnLabel: settingsEntryResources.OobeSettingsOn,
                valueOffLabel: settingsEntryResources.OobeSettingsOff,
                value2OnLabel: settingsEntryResources.OobeSettingsOn,
                value2OffLabel: settingsEntryResources.OobeSettingsOff,
                value: false
            };

            let settings = [
                locationSetting,
                findMyDeviceSetting,
                telemetrySetting,
                inputDiagnosticSetting,
                personalizedOffersSetting,
                personalizedOffersWindowsDiagnosticsSetting,
                tailoredExperiencesSetting, // When Feature_OobePersonalizedOffers is fully enabled, TailoredExperiences should be removed
                humanPresenceSetting
            ];

            // Create an array to show the applicable settings
            let applicableSettings = [];
            for (let setting of settings) {
                // this.initialUserSettings array is in the format [ kind, bool, kind, bool, ... ]
                let initialUserSettingIndex = this.initialUserSettings.indexOf(setting.settingKind);

                if ((initialUserSettingIndex != -1) && (initialUserSettingIndex + 1 < this.initialUserSettings.length)) {
                    setting.value = this.initialUserSettings[initialUserSettingIndex + 1];
                    applicableSettings.push(setting);
                }
            }
            return applicableSettings;
        }

        getLearnMoreContent() {
            return this.learnMoreContent;
        }

        updateLearnMoreContentForRender(iFrameElement, doc, dirVal, isInternetAvailable, errorMessage, scrollTitle, elementToAnchor) {
            // Set the content of the iframe to the learn more content
            doc.body.innerHTML = this.getLearnMoreContent();
            // Set learn more scroll region title here for screen reader to read
            doc.body.title = scrollTitle;
            // Make body focusable
            doc.body.setAttribute('tabindex', '0');
            // Styling on the local resource html content is managed by applying cssOverride
            let cssOverride = "/webapps/inclusiveOobe/css/light-iframe-content.css";
            let fileRef = doc.head.ownerDocument.createElement("link");
            fileRef.setAttribute("rel", "stylesheet");
            fileRef.setAttribute("href", cssOverride);
            if (elementToAnchor) {
                // If we're overriding CSS and elementToAnchor is provided (e.g. in the Multi-page OOBE privacy settings scenario),
                // only anchor the Learn More content to that element once the stylesheet has loaded
                    let elemString = this.privacySettingKindToString(elementToAnchor.settingKind);
                    fileRef.onload = function() {
                        let anchor = doc.getElementById(elemString);
                        if (anchor) {
                            anchor.scrollIntoView();
                        }
                    }
            }
            doc.head.appendChild(fileRef);
            doc.body.focus();
    
            let privacyLinks = doc.querySelectorAll("a");
            for (let i = 0; i < privacyLinks.length; i++) {
                let link = privacyLinks[i];
                link.onclick = (e) => {
                    this.showLearnMoreContent(iFrameElement, doc, e.target.href, dirVal, isInternetAvailable, errorMessage);
                    e.preventDefault();
                };
            }
        }

        showLearnMoreContent(iFrameElement, doc, href, dirVal, isInternetAvailable, errorMessage) {
            // Styling on the local resource html content is managed by applying cssOverride
            let cssOverride = "/webapps/inclusiveOobe/css/light-iframe-content.css";      
            if (isInternetAvailable) {
                let url = href + "&profile=transparentLight";
                WinJS.xhr({ url: url }).then((response) => {
                    // TODO: task.ms/58115852 - Might need a Narrator accessibility fix to add a name property for screen reader
                    doc.location.href = url;
                    doc.body.focus();
                }, (error) => {
                    let html = "<html><head><link href=\"" + cssOverride + "\" rel=\"stylesheet\">";
                    html = html + "</head><body><p>" + errorMessage + "</p></body></html>";
                    KoHelpers.loadIframeContent(iFrameElement, doc, { content: html, dir: dirVal });
                });
            }
            else {
                let innerHTML = "<html><head><link href=\"" + cssOverride + "\" rel=\"stylesheet\">";
                innerHTML = innerHTML + "</head><body><p>" + errorMessage + "</p></body></html>";
                doc.body.innerHTML = innerHTML;
            }
        }
    }
    return new OobePrivacySettingsData();
});

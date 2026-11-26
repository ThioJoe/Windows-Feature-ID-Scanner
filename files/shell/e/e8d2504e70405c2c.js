
define(['legacy/core'], (core) => {
    class OOBEAutoPilot {
        launchAsync(currentNode) {
            return new WinJS.Promise(async function (completeDispatch) {
                try {
                    const OS_DEFAULT = "os-default";
                    let autoPilot = new EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotServer();
                    switch (currentNode.policyName) {
                        case "CloudAssignedLanguage":
                            try {
                                CloudExperienceHost.AutoPilot.logInfoEvent(
                                    "CommercialOOBE_AutopilotLanguage_SettingRetrieval_Started",
                                    "Retrieving Autopilot language settings policy.");

                                let policyValue = await autoPilot.getStringPolicyAsync(currentNode.policyName);

                                CloudExperienceHost.AutoPilot.logInfoEvent(
                                    "CommercialOOBE_AutopilotLanguage_SettingRetrieval_Succeeded",
                                    "Successfully retrieved Autopilot language settings policy.");

                                if (policyValue) {
                                    let languageManager = AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.OobeDisplayLanguageManagerCore");
                                    let languages = CloudExperienceHostAPI.OobeDisplayLanguagesCore.getDisplayLanguages();
                                    let policyLanguage = languages.find((language) => language.tag.localeCompare(policyValue, undefined, { sensitivity: 'base' }) === 0); // String-insensitive compare, allows accent marks to be treated the same if the same base

                                    if ((!policyLanguage) ||
                                        (policyValue === OS_DEFAULT)) {
                                        policyLanguage = languages[0];
                                    }

                                    CloudExperienceHost.AutoPilot.logInfoEvent(
                                        "CommercialOOBE_AutopilotLanguage_SettingApplication_Started",
                                        "Applying Autopilot language settings policy.");

                                    languageManager.commitDisplayLanguageAsync(policyLanguage).action.done(() => {
                                        CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotLanguage_SettingApplication_Success", "Language set by AutoPilot policy");

                                        completeDispatch(CloudExperienceHost.AppResult.success);
                                    });
                                } else {
                                    completeDispatch(CloudExperienceHost.AppResult.success);
                                }
                            } catch (e) {
                                CloudExperienceHost.AutoPilot.logInfoEvent(
                                    "CommercialOOBE_AutopilotLanguage_SettingRetrieval_Failed",
                                    `Error getting Autopilot string policy '${currentNode.policyName}'`);
                                completeDispatch(CloudExperienceHost.AppResult.fail);
                            }
                            break;

                        case "CloudAssignedRegion":
                            try {
                                CloudExperienceHost.AutoPilot.logInfoEvent(
                                    "CommercialOOBE_AutopilotRegion_SettingRetrieval_Started",
                                    "Retrieving Autopilot region settings policy.");

                                let policyValue = await autoPilot.getStringPolicyAsync(currentNode.policyName);

                                CloudExperienceHost.AutoPilot.logInfoEvent(
                                    "CommercialOOBE_AutopilotRegion_SettingRetrieval_Succeeded",
                                    "Successfully retrieved Autopilot region settings policy.");

                                if (policyValue) {
                                    let regionCode = policyValue;

                                    if (policyValue === OS_DEFAULT) {
                                        regionCode = CloudExperienceHost.Globalization.GeographicRegion.getCode().toLowerCase();
                                    }

                                    CloudExperienceHost.AutoPilot.logInfoEvent(
                                        "CommercialOOBE_AutopilotRegion_SettingApplication_Started",
                                        "Applying Autopilot region settings policy.");

                                    let regionManager = AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.OobeRegionManagerStaticsCore");
                                    let commitRegion = regionManager.commitRegionAsync(regionCode);
                                    commitRegion.action.done(() => {
                                        CloudExperienceHost.AutoPilot.logInfoEvent(
                                            "CommercialOOBE_AutopilotRegion_SettingApplication_Succeeded",
                                            "Region set by AutoPilot policy.");
                                        if (commitRegion.effects.rebootRequired) {
                                            CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotRegion_RebootRequired", "CommitRegionRebootRequired");
                                        }

                                        let keyboardManager = AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.OobeKeyboardManagerStaticsCore");
                                        let keyboards = CloudExperienceHostAPI.OobeKeyboardStaticsCore.getKeyboardsForDefaultInputLanguage();
                                        let defaultKeyboard = [keyboards[0]]; // Set to the first default keyboard in the list
                                        keyboardManager.commitKeyboardsAsync(defaultKeyboard).done(() => {
                                            CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotKeyboard_SettingApplication_Succeeded", "Keyboard set by AutoPilot policy");

                                            CloudExperienceHost.setShowInputSwitchButton();

                                            completeDispatch(CloudExperienceHost.AppResult.success);
                                        }, (err) => {
                                            CloudExperienceHost.AutoPilot.logInfoEvent(
                                                "CommercialOOBE_AutopilotRegion_SettingApplication_Failed",
                                                "Failed to set region by AutoPilot policy.");
                                        });
                                    });
                                } else {
                                    completeDispatch(CloudExperienceHost.AppResult.success);
                                }
                            } catch (e) {
                                CloudExperienceHost.AutoPilot.logInfoEvent(
                                    "CommercialOOBE_AutopilotRegion_SettingRetrieval_Failed",
                                    `Error getting Autopilot string policy '${currentNode.policyName}'`);
                                completeDispatch(CloudExperienceHost.AppResult.fail);
                            }
                            break;

                        case "offlineCheck":
                            autoPilot.getStringPolicyAsync("CloudAssignedTenantId").then(function (policyValue) {
                                if ((policyValue === null) || (policyValue === "")) {
                                    completeDispatch(CloudExperienceHost.AppResult.success);
                                } else {
                                    completeDispatch(CloudExperienceHost.AppResult.action1);
                                }
                            }, function (err) {
                                completeDispatch(CloudExperienceHost.AppResult.abort);
                            });
                            break;

                        case "postReset":
                            let pluginManager = new CloudExperienceHostAPI.Provisioning.PluginManager();
                            let isAutopilotReset = pluginManager.isPostPowerwash();

                            CloudExperienceHost.Storage.SharableData.addValue("AADProvisioningPage", "OobeEnterpriseProvisioning");

                            if (isAutopilotReset === true) {
                                CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotPostReset_Flow_Entered", "Device is in a post Autopilot reset flow.");

                                let isHybridDomainJoinEnabled = (await EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getDwordPolicyAsync("CloudAssignedDomainJoinMethod") === 1);

                                if (isHybridDomainJoinEnabled) {
                                    CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotPostReset_DomainJoinFlow_Skipped", "Skipping domain join flow due to Autopilot reset.");
                                    completeDispatch(CloudExperienceHost.AppResult.action2);
                                } else {
                                    CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotPostReset_AadRegistration_Skipped", "Skipping AAD registration flow due to Autopilot reset.");
                                    completeDispatch(CloudExperienceHost.AppResult.action1);
                                }
                            }
                            else {
                                let profileState = await EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getProfileStateAsync();

                                if (EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotProfileState.available === profileState) {
                                    CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_Autopilot_Profile_Available", "Autopilot profile is available.");

                                    let enrollmentStaticApis = new EnterpriseDeviceManagement.Enrollment.ReflectedEnrollmentStatics();

                                    if (enrollmentStaticApis.ShouldSkip() === 1) {
                                        CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_Autopilot_Profile_NonHAADJ", "No Hybrid AADJ specified in the Autopilot profile. Move to AADJ sign-in.");

                                        completeDispatch(CloudExperienceHost.AppResult.action3);
                                    } else {
                                        CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_Autopilot_Profile_HAADJ", "Hybrid AADJ is specified in the Autopilot profile. Move to Hybrid AADJ sign-in.");

                                        completeDispatch(CloudExperienceHost.AppResult.success);
                                    }
                                } else {
                                    CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_Autopilot_Profile_Unavailable", "No Autopilot profile available.");
                                    completeDispatch(CloudExperienceHost.AppResult.success);
                                }
                            }

                            break;

                        case "prefetch":
                            CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotPreFetch_PolicyCache_Started", "AutoPilot prefetch ZTP policy cache started");
                            let startTime = performance.now();
                            let cxidOrResult = CloudExperienceHost.AppResult.success;
                            let clearAndPopulateZTPCachePromise = EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.clearDdsCacheAsync().then(() => {
                                CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotPreFetch_PolicyCache_Cleared", "AutoPilot policy cache cleared");
                            }).then(() => {
                                return EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.retrieveSettingsAsync();
                            }).then(() => {
                                let details = { timeElapsed: performance.now() - startTime };
                                CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotPreFetch_PolicyCache_Returned", "AutoPilot prefetch ZTP policy cache returned" + JSON.stringify(details));
                            }, (error) => {
                                CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotPreFetch_PolicyCache_Failed", "AutoPilot prefetch ZTP policy cache failed");
                            }).then(() => {
                                return EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getCXIDPostRebootAsync();
                            }).then((cxidToJumpTo) => {
                                const UpdateRebootCXIDKey = "UpdateRebootCXID";
                                if ((cxidToJumpTo !== null) && (cxidToJumpTo !== "")) {
                                    let lastResetWasFromAutopilotUpdate = CloudExperienceHost.Storage.SharableData.getValue("resetFromAutopilotUpdate");
                                    if (lastResetWasFromAutopilotUpdate) {
                                        cxidOrResult = cxidToJumpTo;
                                        CloudExperienceHost.Storage.SharableData.addValue("resetFromAutopilotUpdate", false);
                                        return autoPilot.storeSettingAsync(UpdateRebootCXIDKey, "");
                                    }
                                }
                            });

                            let timedOut = false;
                            let timeoutPromise = WinJS.Promise.timeout(36000 /*36 second timeout*/).then(() => { timedOut = true; });
                            WinJS.Promise.any([clearAndPopulateZTPCachePromise, timeoutPromise]).then((result) => {
                                if (timedOut) {
                                    CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotPreFetch_PolicyCache_TimedOut", "AutoPilot prefetch ZTP policy cache timed out");
                                } else {
                                    CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutopilotPreFetch_PolicyCache_Success", "AutoPilot prefetch ZTP policy cache done");
                                }

                                completeDispatch(cxidOrResult);
                            }, function (err) {
                                completeDispatch(CloudExperienceHost.AppResult.fail);
                            });
                            break;

                        case "BitlockerDeferralRelease":
                            let bitLockerDeferralEnabled = CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("AutopilotBitlockerOobeDeferral");
                            if (bitLockerDeferralEnabled) {
                                try {
                                    CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_BitlockerDeferral_Started", `Autopilot Bitlocker deferral release signaling started for '${currentNode.cxid}'`);

                                    let reasonCode = 0; // BitLockerDeferralReason.NotAvailable
                                    switch (currentNode.cxid) {
                                        case 'BitlockerDeferralReleasePostMdm':
                                            reasonCode = 3; // BitLockerDeferralReason.MdmSyncComplete
                                            break;
                                        case 'BitlockerDeferralReleasePostLocal':
                                        case 'BitlockerDeferralReleasePostMSA':
                                        default:
                                            reasonCode = 2; // BitLockerDeferralReason.NotMdmEnrolled
                                            break;
                                    }

                                    ModernDeployment.Autopilot.Core.AutopilotWnfNotificationManagerStatics.setBitlockerDeferralComplete(reasonCode);

                                    CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_BitlockerDeferral_Success", "Autopilot Bitlocker deferral release signaling succeeded");
                                } catch (err) {
                                    CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_BitlockerDeferral_Failed", `Error: ${err.message}, Name: ${err.name}, Stack: ${err.stack}`);
                                }
                            }

                            completeDispatch(CloudExperienceHost.AppResult.success);
                            break;

                        case "AutoAcceptEula":
                            {
                                CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutoAcceptEula_Started", "EULA auto-accept for Autopilot devices started");

                                try {
                                    let autopilotAutoAcceptEula = EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getOobeSettingsOverride(EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotOobeSetting.skipAcceptEula);

                                    if (autopilotAutoAcceptEula) {
                                        CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutoAcceptEula_BeginAccept", "EULA auto-accept is enabled, beginning acceptance");
                                        await CloudExperienceHostAPI.OobeEulaManagerStaticsCore.acceptEulaAsync();
                                        CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutoAcceptEula_Success", "EULA auto-accept succeeded");
                                    } else {
                                        CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutoAcceptEula_Skipped", "EULA auto-accept is not enabled and was skipped");
                                    }
                                } catch (err) {
                                    CloudExperienceHost.AutoPilot.logInfoEvent(
                                        "CommercialOOBE_AutoAcceptEula_Failed",
                                        JSON.stringify(err));
                                }

                                CloudExperienceHost.AutoPilot.logInfoEvent("CommercialOOBE_AutoAcceptEula_Completed", "EULA auto-accept complete");

                                completeDispatch(CloudExperienceHost.AppResult.success);
                            }
                            break;

                        default:
                            completeDispatch(CloudExperienceHost.AppResult.success);
                            break;
                    }
                } catch (err) {
                    CloudExperienceHost.AutoPilot.logInfoEvent(
                        "CommercialOOBE_AutopilotPreFetch_AppLauncher_Failed",
                        `Failed to run app launcher Autopilot policy '${currentNode.policyName}' for node '${currentNode.cxid}'`);
                    completeDispatch(CloudExperienceHost.AppResult.fail);
                }
            });
        }
    }
    return OOBEAutoPilot;
});

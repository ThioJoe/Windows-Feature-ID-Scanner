"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    var BackupRestore;
    (function (BackupRestore) {
        function setRestoreProfileAsync(profileId, correlationVector) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch) {
                if ((correlationVector === null) || (correlationVector === undefined)) {
                    correlationVector = "";
                }
                CloudExperienceHostAPI.BackupRestoreManager.setRestoreProfileAsync(profileId, correlationVector).done(function () {
                    completeDispatch();
                }, function (e) { errorDispatch(e); });
            });
        }
        BackupRestore.setRestoreProfileAsync = setRestoreProfileAsync;
        function downloadUserRestoreDataAsync(deviceProfileId, profileDataRoamingUserToken) {
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeRestoreDataLayer")) {
                return CloudExperienceHostAPI.BackupRestoreManager.downloadUserRestoreDataAsync(deviceProfileId, profileDataRoamingUserToken);
            }
            else {
                CloudExperienceHost.Telemetry.logEvent("Feature_OobeRestoreDataLayer_Disabled", "downloadUserRestoreDataAsync");
                throw "ApiNonexistentOnClient";
            }
        }
        BackupRestore.downloadUserRestoreDataAsync = downloadUserRestoreDataAsync;
        function setSystemRestoreEnabledAsync(enabled) {
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeRestoreDataLayer")) {
                return CloudExperienceHostAPI.BackupRestoreManager.setSystemRestoreEnabledAsync(enabled);
            }
            else {
                CloudExperienceHost.Telemetry.logEvent("Feature_OobeRestoreDataLayer_Disabled", "setSystemRestoreEnabledAsync");
                throw "ApiNonexistentOnClient";
            }
        }
        BackupRestore.setSystemRestoreEnabledAsync = setSystemRestoreEnabledAsync;
        function downloadUserFileAsync(userFileType, userFileUri, userFileRequestHeaders, localSavedFileName, timeoutInSecs) {
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeRestoreDataLayer")) {
                if ((userFileUri != null) && (userFileUri.trim() != "")) {
                    CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}`, CloudExperienceHost.UriHelper.RemovePIIFromUri(userFileUri));
                    if ((localSavedFileName == null) || (localSavedFileName.trim() == "")) {
                        CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error_InvalidLocalSavedFileName`);
                        throw "InvalidLocalSavedFileName";
                    }
                    const restoreFolderName = "cloudrestore";
                    const fileFolderName = userFileType.toLowerCase();
                    let localFileUri = "ms-appdata:///local/" + restoreFolderName + "/" + fileFolderName + "/" + localSavedFileName;
                    CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_FileDownloadStarted`);
                    try {
                        let httpClient = new Windows.Web.Http.HttpClient();
                        let requestHeaders = httpClient.defaultRequestHeaders;
                        let fileUri = new Windows.Foundation.Uri(userFileUri);
                        if (userFileRequestHeaders) {
                            for (const key in userFileRequestHeaders) {
                                if (!requestHeaders.tryAppendWithoutValidation(key, userFileRequestHeaders[key])) {
                                    CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error_HeaderAppendFailure`, key);
                                }
                            }
                        }
                        let fileDownloadComplete = false;
                        let timedOut = false;
                        let timeoutPromise = WinJS.Promise.timeout(timeoutInSecs * 1000 /* to milliseconds */).then(() => { timedOut = true; return null; });
                        let userFile;
                        let downloadPromise = Windows.Storage.ApplicationData.current.localFolder.createFolderAsync(restoreFolderName, Windows.Storage.CreationCollisionOption.openIfExists)
                            .then((cloudRestoreFolder) => {
                            return cloudRestoreFolder.createFolderAsync(fileFolderName, Windows.Storage.CreationCollisionOption.openIfExists);
                        }, (error) => {
                            CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error_CloudRestoreFolderCreationFailed`);
                            throw CloudExperienceHost.GetJsonFromError(error);
                        }).then((userFileFolder) => {
                            return userFileFolder.createFileAsync(localSavedFileName, Windows.Storage.CreationCollisionOption.replaceExisting);
                        }, (error) => {
                            CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error_ImageFolderCreationFailed`);
                            throw CloudExperienceHost.GetJsonFromError(error);
                        }).then((file) => {
                            userFile = file;
                            return httpClient.getBufferAsync(fileUri);
                        }, (error) => {
                            CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error_ImageFileCreationFailed`);
                            throw CloudExperienceHost.GetJsonFromError(error);
                        }).then((buffer) => {
                            return Windows.Storage.FileIO.writeBufferAsync(userFile, buffer);
                        }, (error) => {
                            CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error_HttpRequestFailed`);
                            throw CloudExperienceHost.GetJsonFromError(error);
                        }).then(() => {
                            fileDownloadComplete = true;
                            CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_FileDownloadComplete`);
                            return userFile.path;
                        });
                        return WinJS.Promise.any([downloadPromise, timeoutPromise]).then((localpath) => {
                            if (fileDownloadComplete) {
                                CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_LocalUriReturnedToCaller`);
                                return localFileUri;
                            }
                            else if (timedOut) {
                                CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error_DownloadTimedOut`);
                                throw `DownloadTimedOut_${userFileType}`;
                            }
                            throw `DownloadInterruptedError_${userFileType}`;
                        }, (error) => {
                            let errorAsString = CloudExperienceHost.GetJsonFromError(error);
                            CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error_DownloadError`, errorAsString);
                            throw `DownloadError_${userFileType}`;
                        });
                    }
                    catch (error) {
                        let errorAsString = CloudExperienceHost.GetJsonFromError(error);
                        CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error`, errorAsString);
                        throw errorAsString;
                    }
                }
                CloudExperienceHost.Telemetry.logEvent(`downloadUserFileAsync_${userFileType}_error_FileUriIsEmpty`);
                throw `FileUriIsEmpty_${userFileType}`;
            }
            else {
                CloudExperienceHost.Telemetry.logEvent("Feature_OobeRestoreDataLayer_Disabled", "downloadUserFileAsync");
                throw "ApiNonexistentOnClient";
            }
        }
        function downloadUserWallpaperAsync(userWallpaperUri, userWallpaperHeaders, localWallpaperFileName, timeoutInSecs = 90) {
            return downloadUserFileAsync("Wallpaper", userWallpaperUri, userWallpaperHeaders, localWallpaperFileName, timeoutInSecs);
        }
        BackupRestore.downloadUserWallpaperAsync = downloadUserWallpaperAsync;
        function downloadUserLockScreenAsync(userLockScreenUri, userLockScreenHeaders, localLockScreenFileName, timeoutInSecs = 90) {
            return downloadUserFileAsync("Lockscreen", userLockScreenUri, userLockScreenHeaders, localLockScreenFileName, timeoutInSecs);
        }
        BackupRestore.downloadUserLockScreenAsync = downloadUserLockScreenAsync;
        function copyWallpaperToUserProfileAsync(appDataUri) {
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeRestoreDataLayer")) {
                let uri = new Windows.Foundation.Uri(appDataUri);
                return Windows.Storage.StorageFile.getFileFromApplicationUriAsync(uri).then((storageFile) => {
                    return CloudExperienceHostAPI.BackupRestoreManager.copyWallpaperToUserProfileAsync(storageFile.path);
                }, (error) => {
                    CloudExperienceHost.Telemetry.logEvent("CopyWallpaperToUserProfileAsync_Error", CloudExperienceHost.GetJsonFromError(error));
                });
            }
            else {
                CloudExperienceHost.Telemetry.logEvent("Feature_OobeRestoreDataLayer_Disabled", "copyWallpaperToUserProfileAsync");
                throw "ApiNonexistentOnClient";
            }
        }
        BackupRestore.copyWallpaperToUserProfileAsync = copyWallpaperToUserProfileAsync;
        function copyLockscreenToUserProfileAsync(appDataUri) {
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeRestoreDataLayer")) {
                let uri = new Windows.Foundation.Uri(appDataUri);
                return Windows.Storage.StorageFile.getFileFromApplicationUriAsync(uri).then((storageFile) => {
                    return CloudExperienceHostAPI.BackupRestoreManager.copyLockscreenToUserProfileAsync(storageFile.path);
                }, (error) => {
                    CloudExperienceHost.Telemetry.logEvent("CopyLockscreenToUserProfileAsync_Error", CloudExperienceHost.GetJsonFromError(error));
                });
            }
            else {
                CloudExperienceHost.Telemetry.logEvent("Feature_OobeRestoreDataLayer_Disabled", "copyLockscreenToUserProfileAsync");
                throw "ApiNonexistentOnClient";
            }
        }
        BackupRestore.copyLockscreenToUserProfileAsync = copyLockscreenToUserProfileAsync;
        function cleanupUserRestoreDataAsync() {
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeRestoreDataLayer")) {
                return CloudExperienceHostAPI.BackupRestoreManager.cleanupUserRestoreDataAsync();
            }
            else {
                CloudExperienceHost.Telemetry.logEvent("Feature_OobeRestoreDataLayer_Disabled", "cleanupUserRestoreDataAsync");
                throw "ApiNonexistentOnClient";
            }
        }
        BackupRestore.cleanupUserRestoreDataAsync = cleanupUserRestoreDataAsync;
        var OobeCloudBackupRestore;
        (function (OobeCloudBackupRestore) {
            function getShouldSkipAsync() {
                return new WinJS.Promise(function (completeDispatch /*, errorDispatch */) {
                    if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OOBEGamingHandheldNavigation")) {
                        if (CloudExperienceHost.Environment.isGamepadBasedDevice()) {
                            completeDispatch(true);
                        }
                    }
                    let policyValue = CloudExperienceHostAPI.UtilStaticsCore.getLicensingPolicyValue("OOBE-Skip-CloudBackupRestore");
                    completeDispatch(policyValue != 0);
                });
            }
            OobeCloudBackupRestore.getShouldSkipAsync = getShouldSkipAsync;
        })(OobeCloudBackupRestore = BackupRestore.OobeCloudBackupRestore || (BackupRestore.OobeCloudBackupRestore = {}));
        var OobeAadCloudBackupRestore;
        (function (OobeAadCloudBackupRestore) {
            function getShouldSkipAsync() {
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("CommercialBrOOBETelemetry")) {
                    CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_RestoreCodePresent");
                }
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OOBERestoreFlowControlforAAD")) {
                    return new WinJS.Promise(function (completeDispatch, errorDispatch) {
                        let licensingPolicyPromise = WinJS.Promise.wrap(CloudExperienceHostAPI.UtilStaticsCore.getLicensingPolicyValue("OOBE-Skip-CloudBackupRestore"));
                        let cspPromise = isRestoreAllowedByPolicyAsync();
                        let regKeyPath = "Software\\Microsoft\\Windows\\CurrentVersion\\WindowsBackupAndRestore\\NodeValues";
                        let regValueNameRestoreFlowStatus = "RestoreFlowStatus";
                        let regValueNameRestoreFlowTimeStamp = "RestoreFlowTimeStamp";
                        WinJS.Promise.join([licensingPolicyPromise, cspPromise]).then(([licensingPolicyValue, cspValue]) => {
                            let shouldSkip = false;
                            if (licensingPolicyValue != 0) {
                                shouldSkip = true;
                                CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_DisabledBySLPolicy");
                                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RestoreCSPIntuneReporting")) {
                                    CloudExperienceHostAPI.BackupRestoreManager.setRegistryStringValueForRestoreCSPAsync(regValueNameRestoreFlowStatus, "DisabledBySLPolicy");
                                }
                            }
                            else if (cspValue == false) {
                                shouldSkip = true;
                                CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_DisabledByCsp");
                                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RestoreCSPIntuneReporting")) {
                                    CloudExperienceHostAPI.BackupRestoreManager.setRegistryStringValueForRestoreCSPAsync(regValueNameRestoreFlowStatus, "DisabledByCSP");
                                }
                            }
                            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("CommercialBrOOBETelemetry")) {
                                if (shouldSkip == false) {
                                    CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_RestoreEnabled");
                                }
                            }
                            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RestoreCSPIntuneReporting")) {
                                if (shouldSkip == false) {
                                    function getUtcTimestamp() {
                                        return new Date().toISOString();
                                    }
                                    CloudExperienceHostAPI.BackupRestoreManager.setRegistryStringValueForRestoreCSPAsync(regValueNameRestoreFlowTimeStamp, getUtcTimestamp());
                                }
                            }
                            completeDispatch(shouldSkip);
                        }, (error) => {
                            CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_PreloadCheckError", CloudExperienceHost.GetJsonFromError(error));
                            errorDispatch(error);
                        });
                    });
                }
                else {
                    CloudExperienceHost.Telemetry.logEvent("Feature_OOBERestoreFlowControlforAAD_Disabled", "getShouldSkipAsync");
                    throw "ApiNonexistentOnClient";
                }
            }
            OobeAadCloudBackupRestore.getShouldSkipAsync = getShouldSkipAsync;
            function isRestoreAllowedByPolicyAsync() {
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OOBERestoreFlowControlforAAD")) {
                    return new WinJS.Promise(function (completeDispatch, errorDispatch) {
                        try {
                            CloudExperienceHostAPI.BackupRestoreManager.isRestoreAllowedByPolicyAsync().then((isAllowed) => {
                                completeDispatch(isAllowed);
                            });
                        }
                        catch (error) {
                            CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_PolicyBridgeError", CloudExperienceHost.GetJsonFromError(error));
                            errorDispatch(error);
                        }
                    });
                }
                else {
                    CloudExperienceHost.Telemetry.logEvent("Feature_OOBERestoreFlowControlforAAD_Disabled", "isRestoreAllowedByPolicyAsync");
                    throw "ApiNonexistentOnClient";
                }
            }
            function getMicrosoftEntraTenantIdAsync() {
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("GetMicrosoftEntraTenantId")) {
                    return new WinJS.Promise(function (completeDispatch, errorDispatch) {
                        try {
                            CloudExperienceHostAPI.BackupRestoreManager.getMicrosoftEntraTenantIdAsync().then((tenantId) => {
                                completeDispatch(tenantId);
                            }, (error) => {
                                CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_GetMicrosoftEntraTenantIdError", CloudExperienceHost.GetJsonFromError(error));
                                errorDispatch(error);
                            });
                        }
                        catch (error) {
                            CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_GetMicrosoftEntraTenantIdCatch", CloudExperienceHost.GetJsonFromError(error));
                            errorDispatch(error);
                        }
                    });
                }
                else {
                    CloudExperienceHost.Telemetry.logEvent("Feature_GetMicrosoftEntraTenantId_Disabled", "getMicrosoftEntraTenantIdAsync");
                    throw "ApiNonexistentOnClient";
                }
            }
            OobeAadCloudBackupRestore.getMicrosoftEntraTenantIdAsync = getMicrosoftEntraTenantIdAsync;
            function setRegistryStringValueForRestoreCSPAsync(regValueName, regValue) {
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RestoreCSPIntuneReporting")) {
                    return new WinJS.Promise(function (completeDispatch, errorDispatch) {
                        try {
                            CloudExperienceHostAPI.BackupRestoreManager.setRegistryStringValueForRestoreCSPAsync(regValueName, regValue).then(() => {
                                completeDispatch();
                            }, (error) => {
                                CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_SetRegistryStringValueForRestoreCSPAsync_Error", CloudExperienceHost.GetJsonFromError(error));
                                errorDispatch(error);
                            });
                        }
                        catch (error) {
                            CloudExperienceHost.Telemetry.logEvent("OobeAADCloudBackupRestore_SetRegistryStringValueForRestoreCSPAsync_Catch", CloudExperienceHost.GetJsonFromError(error));
                            errorDispatch(error);
                        }
                    });
                }
                else {
                    CloudExperienceHost.Telemetry.logEvent("Feature_RestoreCSPIntuneReporting_Disabled", "SetRegistryStringValueForRestoreCSPAsync");
                    throw "ApiNonexistentOnClient";
                }
            }
            OobeAadCloudBackupRestore.setRegistryStringValueForRestoreCSPAsync = setRegistryStringValueForRestoreCSPAsync;
        })(OobeAadCloudBackupRestore = BackupRestore.OobeAadCloudBackupRestore || (BackupRestore.OobeAadCloudBackupRestore = {}));
    })(BackupRestore = CloudExperienceHost.BackupRestore || (CloudExperienceHost.BackupRestore = {}));
})(CloudExperienceHost || (CloudExperienceHost = {}));

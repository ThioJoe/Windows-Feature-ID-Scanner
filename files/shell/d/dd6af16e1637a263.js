"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    var MobileExperience;
    (function (MobileExperience) {
        var OOBE;
        (function (OOBE) {
            function getShouldSkipAsync() {
                return new WinJS.Promise(function (completeDispatch, errorDispatch) {
                    let policyValue = CloudExperienceHostAPI.UtilStaticsCore.getLicensingPolicyValue("OOBE-Skip-PhonePairing");
                    completeDispatch(policyValue != 0);
                });
            }
            OOBE.getShouldSkipAsync = getShouldSkipAsync;
        })(OOBE = MobileExperience.OOBE || (MobileExperience.OOBE = {}));

        function setMobileExperienceOptIn() {
            let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
            mobileExperienceManager.mobilityExperienceSettings.optedIn = true;
        }

        function getHasPreviouslyPaired() {
            let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
            return mobileExperienceManager.mobilityExperienceSettings.hasPreviouslyPaired;
        }

        function setHasPreviouslyPaired() {
            let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
            mobileExperienceManager.mobilityExperienceSettings.hasPreviouslyPaired = true;
        }

        function getPairingContext() {
            let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
            return mobileExperienceManager.mobilityExperienceSettings.pairingContext;
        }

        function setPairingContext(pairingContext) {
            let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
            mobileExperienceManager.mobilityExperienceSettings.pairingContext = pairingContext;
        }

        function getSilentPairingContractVersion() {
            let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
            return mobileExperienceManager.mobilityExperienceSettings.silentPairingContractVersion;
        }

        function getShouldSkipAsync() {
            return new WinJS.Promise(function (completeDispatch, errorDispatch) {
                let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
                let isOptedIn = mobileExperienceManager.mobilityExperienceSettings.optedIn;
                let isPinned = mobileExperienceManager.mobilityExperienceSettings.yourPhoneTaskbarIconCreated;
                let hasPreviouslyPaired = mobileExperienceManager.mobilityExperienceSettings.hasPreviouslyPaired;

                ((isOptedIn && isPinned) || hasPreviouslyPaired) ? completeDispatch(true) : completeDispatch(false);
            });
        }

        function tryPinYourPhoneAppToTaskbar() {
            let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
            return mobileExperienceManager.mobilityExperienceSettings.tryPinYourPhoneAppToTaskbar();
        }

        function createYourPhoneTaskbarIconIfNeeded(linkedMobileOS, selectedMobileOS, segmentMobileOS) {
            let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
            mobileExperienceManager.mobilityExperienceSettings.createYourPhoneTaskbarIconIfNeeded(linkedMobileOS, selectedMobileOS, segmentMobileOS);
        }

        function getSettingsQueryString() {
            let flightingInfo = CloudExperienceHostAPI.ContentDeliveryManagerHelpers.getFlightingInfo();
            let queryString = getQueryString();
            let mobileExperienceManager = new ContentManagement.ContentManagementBroker();
            queryString += "&waasBldFlt=" + (flightingInfo.enabled ? "1" : "0");
            queryString += "&waasRing=" + flightingInfo.ring;
            queryString += "&mobilityOptIn=" + (mobileExperienceManager.mobilityExperienceSettings.optedIn ? "1" : "0");
            return queryString;
        }

        function getQueryString() {
            let smbUsage = CloudExperienceHostAPI.ContentDeliveryManagerHelpers.businessUsageIndicator;
            let tailoredExperience = CloudExperienceHostAPI.ContentDeliveryManagerHelpers.tailoredExperiencesEnabled;
            let queryString = "";
            queryString += "isu=" + (smbUsage ? "1" : "0");
            queryString += "&poptin=" + (tailoredExperience ? "1" : "0");
            return queryString;
        }

        MobileExperience.setMobileExperienceOptIn = setMobileExperienceOptIn;
        MobileExperience.getShouldSkipAsync = getShouldSkipAsync;
        MobileExperience.createYourPhoneTaskbarIconIfNeeded = createYourPhoneTaskbarIconIfNeeded;
        MobileExperience.getOobeQueryString = getQueryString;
        MobileExperience.getSettingsQueryString = getSettingsQueryString;
        MobileExperience.getScoobeQueryString = getSettingsQueryString;
        MobileExperience.getHasPreviouslyPaired = getHasPreviouslyPaired;
        MobileExperience.setHasPreviouslyPaired = setHasPreviouslyPaired;
        MobileExperience.getPairingContext = getPairingContext;
        MobileExperience.setPairingContext = setPairingContext;
        MobileExperience.getSilentPairingContractVersion = getSilentPairingContractVersion;
        MobileExperience.tryPinYourPhoneAppToTaskbar = tryPinYourPhoneAppToTaskbar;

    })(MobileExperience = CloudExperienceHost.MobileExperience || (CloudExperienceHost.MobileExperience = {}));
})(CloudExperienceHost || (CloudExperienceHost = {}));

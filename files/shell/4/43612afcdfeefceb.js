"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    var DeviceDisplayNameSetup;
    (function (DeviceDisplayNameSetup) {
        function setDisplayName(displayName) {
            try {
                let resourceAccountManagerSetup = new Microsoft.ResourceAccountManager.ResourceAccountSetup();
                CloudExperienceHost.Storage.SharableData.addValue("resourceAccountDisplayName", displayName);
            }
            catch (err) {
            }
            return Hub.DeviceConfig.DeviceDisplayNameSetup.setDisplayNameAsync(displayName);
        }
        DeviceDisplayNameSetup.setDisplayName = setDisplayName;
    })(CloudExperienceHost.DeviceDisplayNameSetup || (CloudExperienceHost.DeviceDisplayNameSetup = {}));
})(CloudExperienceHost || (CloudExperienceHost = {}));

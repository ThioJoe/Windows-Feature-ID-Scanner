"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    var Policy;
    (function (Policy) {
        function isErrorClassNotReg(e) {
            if (e.hasOwnProperty("number") && ((e.number >>> 0) === 0x80040154)) {
                return true;
            }
            return false;
        }
        function TryOptionallyRegisteredComponentAsyncCallWithDefault(defaultValue, callback) {
            try {
                return callback();
            }
            catch (e) {
                if (isErrorClassNotReg(e)) {
                    return WinJS.Promise.as(() => {
                        return defaultValue;
                    });
                }
                else {
                    throw e;
                }
            }
        }
        function getAutoPilotPolicyDwordAsync(policyName) {
            return TryOptionallyRegisteredComponentAsyncCallWithDefault(0, () => {
                return EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getDwordPolicyAsync(policyName);
            });
        }
        Policy.getAutoPilotPolicyDwordAsync = getAutoPilotPolicyDwordAsync;
        function getAutoPilotPolicyStringAsync(policyName) {
            return TryOptionallyRegisteredComponentAsyncCallWithDefault("", () => {
                return EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getStringPolicyAsync(policyName);
            });
        }
        Policy.getAutoPilotPolicyStringAsync = getAutoPilotPolicyStringAsync;
        function getAutoPilotOobeSettingsOverrideAsync(autoPilotOobeSetting) {
            return TryOptionallyRegisteredComponentAsyncCallWithDefault(false, () => {
                return EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getOobeSettingsOverrideAsync(autoPilotOobeSetting);
            });
        }
        Policy.getAutoPilotOobeSettingsOverrideAsync = getAutoPilotOobeSettingsOverrideAsync;
    })(Policy = CloudExperienceHost.Policy || (CloudExperienceHost.Policy = {}));
})(CloudExperienceHost || (CloudExperienceHost = {}));
if ((typeof define === "function") && define.amd) {
    define(function () {
        return {
            Policy: CloudExperienceHost.Policy,
        };
    });
}

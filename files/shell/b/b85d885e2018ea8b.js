define(['lib/knockout', 'legacy/bridge', 'legacy/core'], (ko, bridge, core) => {
    class OobeEULAData {
        getEulaFileStringAsync(eulaType) {
            return CloudExperienceHostAPI.OobeEulaManagerStaticsCore.getEulaFileAsync(eulaType).then((fileString) => {
                if (fileString && (fileString.length > 0)) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "GetEulaFileAsyncValidFileSuccess");
                    return fileString;
                }
                else if (eulaType === CloudExperienceHostAPI.EulaType.microsoft) {
                    let err = "getEulaFileAsync succeeded with empty file for Microsoft type.";
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "GetEulaFileAsyncEmptyFileMicrosoftSuccess");
                    bridge.invoke("CloudExperienceHost.Telemetry.oobeHealthEvent", CloudExperienceHostAPI.HealthEvent.microsoftEulaShownResult, 0x80070002);
                    throw err;
                }
                else {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "GetEulaFileAsyncEmptyFileOEMSuccess");
                    bridge.invoke("CloudExperienceHost.Telemetry.oobeHealthEvent", CloudExperienceHostAPI.HealthEvent.oemEulaShownResult, 0x80070002);
                }
            }, (err) => {
                if (eulaType === CloudExperienceHostAPI.EulaType.microsoft) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "GetEulaFileAsyncMicrosoftFailure", core.GetJsonFromError(err));
                    bridge.invoke("CloudExperienceHost.Telemetry.oobeHealthEvent", CloudExperienceHostAPI.HealthEvent.microsoftEulaShownResult, err.number ? err.number : 0x8000ffff);
                    throw err;
                }
                else {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "GetEulaFileAsyncOEMFailure", core.GetJsonFromError(err));
                    bridge.invoke("CloudExperienceHost.Telemetry.oobeHealthEvent", CloudExperienceHostAPI.HealthEvent.oemEulaShownResult, err.number ? err.number : 0x8000ffff);
                }
            });
        }

        getEulaData() {
            let eulaData = {
                msEulaString: "",
                hasOEMEula: false,
                oemEulaString: ""
            };

            return this.getEulaFileStringAsync(CloudExperienceHostAPI.EulaType.microsoft).then((msFileString) => {
                eulaData.msEulaString = msFileString;
                bridge.invoke("CloudExperienceHost.Telemetry.oobeHealthEvent", CloudExperienceHostAPI.HealthEvent.microsoftEulaShownResult, 0);
                return this.getEulaFileStringAsync(CloudExperienceHostAPI.EulaType.oem);
            }).then((oemFileString) => {
                if (oemFileString) {
                    eulaData.hasOEMEula = true;
                    eulaData.oemEulaString = oemFileString;
                    bridge.invoke("CloudExperienceHost.Telemetry.oobeHealthEvent", CloudExperienceHostAPI.HealthEvent.oemEulaShownResult, 0);
                }
                return eulaData;
            });
        }
    }
    return new OobeEULAData();
});
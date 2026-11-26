"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    var Rewards;
    (function (Rewards) {
        var shouldReportRewards;
        function setShouldReportRewards(f) {
            shouldReportRewards = f;
        }
        Rewards.setShouldReportRewards = setShouldReportRewards;

        function reportRewardsActivityRestAsync(token) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch) {
                try {
                    let url = "https://prod.rewardsplatform.microsoft.com/dapi/me/activities"; // REST Api
                    let xhr = new XMLHttpRequest();
                    xhr.open("POST", url, true);
                    xhr.setRequestHeader("Content-type", "application/json");
                    xhr.setRequestHeader("Authorization", "Bearer " + token);
                    xhr.onreadystatechange = function() {
                        if (xhr.readyState === 4) { // 4 is DONE
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("ReportRewardsActivityStatus", xhr.status.toString());
                            completeDispatch(xhr.status);
                        }
                    };
                    xhr.send(JSON.stringify({"type": 200, "amount": 1, "country": CloudExperienceHost.Globalization.GeographicRegion.getCode().toLowerCase()}));
                } catch (ex) {
                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("ReportRewardsActivityError", CloudExperienceHost.GetJsonFromError(ex));
                    errorDispatch(ex);
                }
            });
        }

        function reportRewardsActivityAsync() {
            throw "ApiNonexistentOnClient";
        }
        Rewards.reportRewardsActivityAsync = reportRewardsActivityAsync;
    })(CloudExperienceHost.Rewards || (CloudExperienceHost.Rewards = {}));
})(CloudExperienceHost || (CloudExperienceHost = {}));

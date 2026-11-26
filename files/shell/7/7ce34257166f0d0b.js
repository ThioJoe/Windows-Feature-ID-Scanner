
define(() => {
    class OOBERetailDemoEntry {
        launchAsync(currentNode) {
            return new WinJS.Promise(function (completeDispatch /*, errorDispatch, progressDispatch */) {
                if (CloudExperienceHost.Storage.SharableData.getValue("retailDemoEnabled")) {
                    CloudExperienceHost.Storage.SharableData.removeValue("retailDemoEnabled");
                    completeDispatch(CloudExperienceHost.AppResult.action1);
                }
                else {
                    if (CloudExperienceHost.AccountAndServices.shouldSkipAccountAndServices()) {
                        completeDispatch(CloudExperienceHost.AppResult.action2);
                    }
                    else {
                        completeDispatch(CloudExperienceHost.AppResult.success);
                    }
                }
            });
        }
    }
    return OOBERetailDemoEntry;
});

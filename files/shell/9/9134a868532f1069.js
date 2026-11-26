
define(() => {
    class InPlaceResume {
        launchAsync() {
            return new WinJS.Promise(function (completeDispatch /*, errorDispatch, progressDispatch */) {
                let volatileResumeCxid = CloudExperienceHost.Storage.VolatileSharableData.getItem("InPlaceResumeValues", "volatileResumeCxid");
                if (volatileResumeCxid) {
                    CloudExperienceHost.Storage.VolatileSharableData.removeItem("InPlaceResumeValues", "volatileResumeCxid");

                    let reconnectionHandledCount = CloudExperienceHost.Storage.VolatileSharableData.getItem("InPlaceResumeValues", "reconnectionHandledCount");
                    if (reconnectionHandledCount && (typeof(reconnectionHandledCount) === "number")) {
                        CloudExperienceHost.Storage.VolatileSharableData.addItem("InPlaceResumeValues", "reconnectionHandledCount", reconnectionHandledCount + 1);
                    } else {
                        CloudExperienceHost.Storage.VolatileSharableData.addItem("InPlaceResumeValues", "reconnectionHandledCount", 1);
                    }
                    completeDispatch(volatileResumeCxid);
                }
                else {
                    completeDispatch(CloudExperienceHost.AppResult.fail);
                }
            });
        }
    }
    return InPlaceResume;
});

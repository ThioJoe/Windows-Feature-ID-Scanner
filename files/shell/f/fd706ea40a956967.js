define(['lib/knockout', 'legacy/navigationManager', 'legacy/appViewManager'], (ko, navManager, appViewManager) => {
    class OobeLightProgressViewModel {
        constructor(params) {
            let res = new Windows.ApplicationModel.Resources.ResourceLoader("resources");

            this.progressText = params.progressText ? params.progressText : ko.observable(res.getString("Progress"));
            this.progressSubtext = params.progressSubtext ? params.progressSubtext : ko.observable("");
            this.showProgressSubtext = ko.observable(params.progressSubtext ? true : false);

            appViewManager.subscribeForUpdateType(this, CloudExperienceHost.FrameViewModelUpdateType.Language);
            appViewManager.subscribeForUpdateType(this, CloudExperienceHost.FrameViewModelUpdateType.UpdateTransitionMessage);
            navManager.subscribeForNavigationEvent(this, CloudExperienceHost.NavigationEvent.LastWebAppFinished);

            let progressTextEle = document.getElementById("_progressText");
            if (progressTextEle && !params.progressText) {
                progressTextEle.style.opacity = 0;
            }
        }

        dispose() {
            appViewManager.unsubscribeForUpdateType(this, CloudExperienceHost.FrameViewModelUpdateType.Language);
        }

        update(updateType, completeDispatch, errorDispatch, updateTag) {
            switch (updateType) {
                case CloudExperienceHost.FrameViewModelUpdateType.Language:
                    this.languageOverridden(updateTag);
                    completeDispatch();
                    break;

                case CloudExperienceHost.FrameViewModelUpdateType.UpdateTransitionMessage:
                    this.updateTransitionMessage(updateTag);
                    completeDispatch();
                    break;
            }
        }

        languageOverridden(updateTag) {
            let result = CloudExperienceHost.StringResources.makeResourceObject("resources", null /* keyList */, updateTag);
            let res = JSON.parse(result);
            this.progressText(res.Progress);
        }

        updateTransitionMessage(updateTag) {
            let progressTextEle = document.getElementById("_progressText");
            progressTextEle.style.opacity = 1;
            progressTextEle.innerHTML = updateTag;
        }

        onNavigationEvent(event, payload) {
            if (event === CloudExperienceHost.NavigationEvent.LastWebAppFinished) {
                let progressTextEle = document.getElementById("_progressText");
                progressTextEle.style.opacity = 0;

                let progressTextTimeout = 15000;
                let timeoutCurr = CloudExperienceHost.getNavMesh().getShowProgressTextAtEndTimeout();
                if (timeoutCurr != null) {
                    progressTextTimeout = timeoutCurr;
                }
                WinJS.Promise.timeout(progressTextTimeout).then(function () {
                    let res = new Windows.ApplicationModel.Resources.ResourceLoader("resources");
                    progressTextEle.style.opacity = 1;
                    progressTextEle.innerHTML = res.getString("EndOfWebappsProgress");
                });
            }
        }
    }
    return OobeLightProgressViewModel;
});

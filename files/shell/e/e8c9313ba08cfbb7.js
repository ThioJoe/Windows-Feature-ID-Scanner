// Copyright (C) Microsoft. All rights reserved.
define(() => {
    class FireFirstOobeWebAppVisibleEvent {
        launchAsync() {
            CloudExperienceHostAPI.Synchronization.onFirstOOBEWebAppVisible();
            CloudExperienceHost.Telemetry.logEvent("FireFirstOobeWebAppVisibleEventSucceeded");
            return WinJS.Promise.as(CloudExperienceHost.AppResult.success);
        }
    }
    return FireFirstOobeWebAppVisibleEvent;
});
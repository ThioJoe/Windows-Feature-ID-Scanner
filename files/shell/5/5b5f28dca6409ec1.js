define(['require', "legacy/bridge",], (require, bridge) => {
    let gamepadEnabledObj = CloudExperienceHostAPI.FeatureStaging.tryGetIsFeatureEnabled("GamepadEnabledOobe");
    if (gamepadEnabledObj.result && gamepadEnabledObj.value) {
        let originalMethod = WinJS.UI.XYFocus._xyFocus;
        let shimMethod = function (direction, keyCode, referenceRect, dontExit) {
            let origResult = originalMethod(direction, keyCode, referenceRect, dontExit);
            if (direction == "up" && !origResult) {
                try {
                    CloudExperienceHostAPI.UtilStaticsCore.injectTabKey(true /*holdShift*/);
                }
                catch(err) {
                }
            }
            return origResult;
        };

        WinJS.UI.XYFocus._keyHandlerStates.RestState.xyFocus = shimMethod;
        WinJS.UI.XYFocus._keyHandlerStates.ToggleModeRestState.xyFocus = shimMethod;
        WinJS.UI.XYFocus._xyFocus = shimMethod;
    }
})

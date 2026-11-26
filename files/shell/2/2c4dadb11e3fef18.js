(() => {
    WinJS.UI.Pages.define("/webapps/inclusiveOobe/view/autopilotwhiteglovelanding-main.html", {
        init: (element, options) => {
            require.config(new RequirePathConfig('/webapps/inclusiveOobe'));

            let loadCssPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                return result.legacy_uiHelpers.LoadCssPromise(document.head, "", result.legacy_bridge);
            });

            let langAndDirPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                return result.legacy_uiHelpers.LangAndDirPromise(document.documentElement, result.legacy_bridge);
            });

            let getLocalizedStringsPromise = requireAsync(['legacy/bridge', 'legacy/core']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.AutoPilot.makeAutopilotResourceObject").then((resultString) => {
                    this.resourceStrings = JSON.parse(resultString);
                }, (error) => {
                    result.legacy_bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_AutopilotWhiteGloveLandingPage_FailedToLoadResource", result.legacy_core.GetJsonFromError(error));
                });
            });

            let isConnectedToNetworkPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.Environment.hasInternetAccess");
            }).then((isConnectedToNetwork) => {
                this.isInternetAvailable = isConnectedToNetwork;
            });

            let getTargetPersonalityPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.getContext");
            }).then((targetContext) => {
                this.targetPersonality = targetContext.personality ? targetContext.personality : CloudExperienceHost.TargetPersonality.InclusiveBlue;
            });

            return WinJS.Promise.join({
                loadCssPromise: loadCssPromise,
                langAndDirPromise: langAndDirPromise,
                getLocalizedStringsPromise: getLocalizedStringsPromise,
                isConnectedToNetworkPromise: isConnectedToNetworkPromise,
                getTargetPersonalityPromise: getTargetPersonalityPromise });
        },
        error: (e) => {
            require([
                'legacy/bridge',
                'legacy/events'], (
                bridge,
                constants) => {

                bridge.fireEvent(constants.Events.done, constants.AppResult.error);
            });
        },
        ready: (element, options) => {
            require([
                'lib/knockout',
                'corejs/knockouthelpers',
                'legacy/bridge',
                'legacy/events',
                'autopilotwhiteglovelanding-vm',
                'lib/knockout-winjs'], (
                ko,
                KoHelpers,
                bridge,
                constants,
                WhiteGloveViewModel) => {

                koHelpers = new KoHelpers();
                koHelpers.registerComponents(CloudExperienceHost.RegisterComponentsScenarioMode.LightProgress, true /*holdForAdditionalRegistration*/);
                koHelpers.registerComponents(CloudExperienceHost.RegisterComponentsScenarioMode.InclusiveOobe);
                window.KoHelpers = KoHelpers;

                let whiteGloveViewModel = new WhiteGloveViewModel(this.resourceStrings, this.isInternetAvailable, this.targetPersonality);

                ko.applyBindings(whiteGloveViewModel);
                KoHelpers.waitForInitialComponentLoadAsync().then(() => {
                    WinJS.Utilities.addClass(document.body, "pageLoaded");
                    bridge.fireEvent(constants.Events.visible, true);
                    KoHelpers.setFocusOnAutofocusElement();
                });
            });
        }
    });
})();

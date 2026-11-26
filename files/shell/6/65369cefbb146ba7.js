(() => {
    WinJS.UI.Pages.define("/webapps/inclusiveOobe/view/oobelocalaccount-main.html", {
        init: (element, options) => {
            require.config(new RequirePathConfig('/webapps/inclusiveOobe'));

            let loadCssPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                return result.legacy_uiHelpers.LoadCssPromise(document.head, "", result.legacy_bridge);
            });

            let langAndDirPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                return result.legacy_uiHelpers.LangAndDirPromise(document.documentElement, result.legacy_bridge);
            });

            let getLocalizedStringsPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "oobeLocalAccount");
            }).then((result) => {
                this.resourceStrings = JSON.parse(result);
            });

            let isConnectedToNetworkPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.Environment.hasInternetAccess");
            }).then((isConnectedToNetwork) => {
                this.isInternetAvailable = isConnectedToNetwork;
            });

            let getPlatformPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.Environment.getPlatform");
            }).then((platform) => {
                this.requirePassword = (platform === CloudExperienceHost.TargetPlatform.SURFACEHUB);
                this.requireRecovery = (platform !== CloudExperienceHost.TargetPlatform.SURFACEHUB);
                this.allowOnlineAccount = (platform !== CloudExperienceHost.TargetPlatform.SURFACEHUB);
            });

            let getPersonalityPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.getContext");
            }).then((targetContext) => {
                this.targetPersonality = targetContext.personality;
            });

            let getShouldRestrictionsApplyInDeviceRegionPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.AgeAppropriateDesignCode.Eligibility.shouldRestrictionsApplyInDeviceRegion");
            }).then((shouldAadcRestrictionsApplyInDeviceRegion) => {
                this.shouldAadcRestrictionsApplyInDeviceRegion = shouldAadcRestrictionsApplyInDeviceRegion;
            });

            this.onlineAccountTargetId = "OobeIDPS";

            return WinJS.Promise.join({ loadCssPromise: loadCssPromise, langAndDirPromise: langAndDirPromise, getLocalizedStringsPromise: getLocalizedStringsPromise, isConnectedToNetworkPromise: isConnectedToNetworkPromise, getPlatformPromise: getPlatformPromise, getPersonalityPromise: getPersonalityPromise, getShouldRestrictionsApplyInDeviceRegionPromise: getShouldRestrictionsApplyInDeviceRegionPromise });
        },
        error: (e) => {
            require(['legacy/bridge', 'legacy/events'], (bridge, constants) => {
                bridge.fireEvent(constants.Events.done, constants.AppResult.error);
            });
        },
        ready: (element, options) => {
            require(['lib/knockout', 'corejs/knockouthelpers', 'legacy/bridge', 'legacy/events', 'oobelocalaccount-vm', 'lib/knockout-winjs', 'corejs/xy-transfer-wrapper-down'], (ko, KoHelpers, bridge, constants, LocalAccountViewModel) => {
                koHelpers = new KoHelpers();
                koHelpers.registerComponents(CloudExperienceHost.RegisterComponentsScenarioMode.InclusiveOobe);
                window.KoHelpers = KoHelpers;

                let vm = new LocalAccountViewModel(this.resourceStrings, this.isInternetAvailable, this.requirePassword, this.requireRecovery, this.allowOnlineAccount, this.onlineAccountTargetId, this.targetPersonality, this.shouldAadcRestrictionsApplyInDeviceRegion);
                ko.applyBindings(vm);
                KoHelpers.waitForInitialComponentLoadAsync().then(() => {
                    WinJS.Utilities.addClass(document.body, "pageLoaded");
                    bridge.fireEvent(constants.Events.visible, true);
                    KoHelpers.setFocusOnAutofocusElement();
                    vm.startVoiceOver();
                });
            });
        }
    });
})();

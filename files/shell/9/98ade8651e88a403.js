(() => {
    WinJS.UI.Pages.define("/webapps/inclusiveOobe/view/oobehello-main.html", {
        init: (element, options) => {
            require.config(new RequirePathConfig('/webapps/inclusiveOobe'));

            let loadCssPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                return result.legacy_uiHelpers.LoadCssPromise(document.head, "", result.legacy_bridge);
            });

            let langAndDirPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                return result.legacy_uiHelpers.LangAndDirPromise(document.documentElement, result.legacy_bridge);
            });

            let getLocalizedStringsPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "oobeHello");
            }).then((result) => {
                this.resourceStrings = JSON.parse(result);
            });

            let getSupportedHelloEnrollmentKindsPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.Hello.getSupportedHelloEnrollmentKinds");
            }).then((kinds) => {
                this.enrollmentKinds = JSON.parse(kinds);
            });

            let getSkipNgcPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.Storage.SharableData.getValue", "SkipNGC");
            }).then((result) => {
                this.skipNgc = result;
            });

            let getPersonalityPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.getContext");
            }).then((targetContext) => {
                this.targetPersonality = targetContext.personality;
            });

            let isConnectedToNetworkPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.Environment.hasInternetAccess");
            }).then((isConnectedToNetwork) => {
                this.isInternetAvailable = isConnectedToNetwork;
            });

            let getLearnMoreContentPromise = requireAsync(['oobesettings-data']).then((result) => {
                return result.oobesettings_data.initializeLearnMoreContentAsync();
            });

            return WinJS.Promise.join({ loadCssPromise: loadCssPromise, langAndDirPromise: langAndDirPromise, getLocalizedStringsPromise: getLocalizedStringsPromise, getSupportedHelloEnrollmentKindsPromise: getSupportedHelloEnrollmentKindsPromise, getSkipNgcPromise: getSkipNgcPromise, getPersonalityPromise: getPersonalityPromise, isConnectedToNetworkPromise: isConnectedToNetworkPromise, getLearnMoreContentPromise: getLearnMoreContentPromise });
        },
        error: (e) => {
            require(['legacy/bridge', 'legacy/events', 'legacy/core'], (bridge, constants, core) => {
                if (e) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentWinJSPageError", core.GetJsonFromError(e));
                } else {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HelloEnrollmentWinJSPageError");
                }
                bridge.fireEvent(constants.Events.done, constants.AppResult.error);
            });
        },
        ready: (element, options) => {
            require(['lib/knockout', 'corejs/knockouthelpers', 'legacy/bridge', 'legacy/events', 'oobehello-vm', 'lib/knockout-winjs', 'corejs/xy-transfer-wrapper-down'], (ko, KoHelpers, bridge, constants, HelloViewModel) => {
                koHelpers = new KoHelpers();
                koHelpers.registerComponents(CloudExperienceHost.RegisterComponentsScenarioMode.InclusiveOobe);
                window.KoHelpers = KoHelpers;

                if (!this.skipNgc && this.enrollmentKinds && (this.enrollmentKinds.face || this.enrollmentKinds.fingerprint)) {
                    if (this.enrollmentKinds.face && this.enrollmentKinds.fingerprint) {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ShowingHelloEnrollmentPage", "Face AND Fingerprint");
                    } else {
                        if (this.enrollmentKinds.face) {
                            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ShowingHelloEnrollmentPage", "Face");
                        } else if (this.enrollmentKinds.fingerprint) {
                            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ShowingHelloEnrollmentPage", "Fingerprint");
                        }
                    }
                    bridge.invoke("CloudExperienceHost.Telemetry.commitIntentPropertyDWORDAsync", "WindowsHello", "LearnMoreAvailable", 1);

                    ko.applyBindings(new HelloViewModel(this.resourceStrings, this.enrollmentKinds, this.targetPersonality, this.isInternetAvailable));
                    KoHelpers.waitForInitialComponentLoadAsync().then(() => {
                        WinJS.Utilities.addClass(document.body, "pageLoaded");
                        bridge.fireEvent(constants.Events.visible, true);
                        KoHelpers.setFocusOnAutofocusElement();
                    });
                } else {
                    if (this.skipNgc) {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "SkipHelloEnrollmentPageViaSharableData");
                    } else {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "NotShowingHelloEnrollmentPage");
                    }
                    bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.abort);
                }
            });
        }
    });
})();

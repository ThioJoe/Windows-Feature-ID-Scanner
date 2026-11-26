(() => {
    var pages = [
        {
            uri: "/webapps/inclusiveOobe/view/oobeprivacysettings-main.html",
            viewmodel: 'oobeprivacysettings-vm'
        }
    ];

    pages.forEach((page) => {
        WinJS.UI.Pages.define(page.uri, {
            init: (element, options) => {
                require.config(new RequirePathConfig('/webapps/inclusiveOobe'));

                // Load css per scenario
                let loadCssPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                    return result.legacy_uiHelpers.LoadCssPromise(document.head, "", result.legacy_bridge);
                });

                let langAndDirPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                    return result.legacy_uiHelpers.LangAndDirPromise(document.documentElement, result.legacy_bridge);
                });

                let getLocalizedStringsPromise = requireAsync(['legacy/bridge']).then((result) => {
                    return result.legacy_bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "oobePrivacySettings");
                }).then((result) => {
                    this.resourceStrings = JSON.parse(result);
                });

                let getSettingsLocalizedStringsPromise = requireAsync(['legacy/bridge']).then((result) => {
                    return result.legacy_bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "oobePrivacySettingsEntry");
                }).then((result) => {
                    this.settingsEntryResourceStrings = JSON.parse(result);
                });

                let initializePrivacySettingsPromise = requireAsync(['oobeprivacysettings-data']).then((result) => {
                    return result.oobeprivacysettings_data.initializePrivacySettingsAsync();
                });

                let isConnectedToNetworkPromise = requireAsync(['legacy/bridge']).then((result) => {
                    return result.legacy_bridge.invoke("CloudExperienceHost.Environment.hasInternetAccess");
                }).then((isConnectedToNetwork) => {
                    this.isInternetAvailable = isConnectedToNetwork;
                });

                return WinJS.Promise.join({ loadCssPromise: loadCssPromise, langAndDirPromise: langAndDirPromise, getLocalizedStringsPromise: getLocalizedStringsPromise, getSettingsLocalizedStringsPromise: getSettingsLocalizedStringsPromise, initializePrivacySettingsPromise: initializePrivacySettingsPromise, isConnectedToNetworkPromise: isConnectedToNetworkPromise });
            },
            error: (e) => {
                require(['legacy/bridge', 'legacy/events'], (bridge, constants) => {
                    bridge.fireEvent(constants.Events.done, constants.AppResult.error);
                });
            },
            ready: (element, options) => {
                require(['lib/knockout', 'corejs/knockouthelpers', 'legacy/bridge', 'legacy/events', page.viewmodel, 'oobeprivacysettings-data', 'lib/knockout-winjs'], (ko, KoHelpers, bridge, constants, OobePrivacySettingsViewModel) => {
                    // Setup knockout customizations
                    koHelpers = new KoHelpers();
                    koHelpers.registerComponents(CloudExperienceHost.RegisterComponentsScenarioMode.InclusiveOobe);
                    window.KoHelpers = KoHelpers;

                    // Apply bindings and show the page
                    let vm = new OobePrivacySettingsViewModel(this.resourceStrings, this.settingsEntryResourceStrings, this.isInternetAvailable);
                    ko.applyBindings(vm);
                    KoHelpers.waitForInitialComponentLoadAsync().then(() => {
                        WinJS.Utilities.addClass(document.body, "pageLoaded");
                        bridge.fireEvent(constants.Events.visible, true);
                        vm.updateForScrollState();
                        KoHelpers.setFocusOnAutofocusElement();
                    });
                });
            }
        });
    });
})();

//
// Copyright (C) Microsoft. All rights reserved.
//
// Standalone LearnMore page for the AADC (child-account) privacy flow. Mirrors
// learnmore-page.js (Hello's Learn More) but loads the oobePrivacySettingsAadc
// resource bundle and does NOT pre-fetch static content via the Privacy bridge --
// AADC pulls its help content live from the required-data-collection fwlink at
// render time via KoHelpers.showLearnMoreContent, matching legacy
// oobeprivacysettings-aadc-vm.js::showLearnMore.
(() => {
    WinJS.UI.Pages.define("/webapps/inclusiveOobe/view/learnmore-aadc-page.html", {
        init: (element, options) => {
            require.config(new RequirePathConfig('/webapps/inclusiveOobe'));

            let loadCssPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                return result.legacy_uiHelpers.LoadCssPromise(document.head, "", result.legacy_bridge);
            });

            let langAndDirPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                return result.legacy_uiHelpers.LangAndDirPromise(document.documentElement, result.legacy_bridge);
            });

            let getLocalizedStringsPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "oobePrivacySettingsAadc");
            }).then((result) => {
                this.resourceStrings = JSON.parse(result);
            });

            let isConnectedToNetworkPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.Environment.hasInternetAccess");
            }).then((isConnectedToNetwork) => {
                this.isInternetAvailable = isConnectedToNetwork;
            }).then(null, () => {
                this.isInternetAvailable = false;
            });

            return WinJS.Promise.join({ loadCssPromise: loadCssPromise, langAndDirPromise: langAndDirPromise, getLocalizedStringsPromise: getLocalizedStringsPromise, isConnectedToNetworkPromise: isConnectedToNetworkPromise });
        },
        error: (e) => {
            require(['legacy/bridge', 'legacy/events'], (bridge, constants) => {
                bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
            });
        },
        ready: (element, options) => {
            require(['lib/knockout', 'corejs/knockouthelpers', 'legacy/bridge', 'legacy/events', 'learnmore-aadc-vm', 'lib/knockout-winjs'], (ko, KoHelpers, bridge, constants, LearnMoreAadcViewModel) => {
                let vm = new LearnMoreAadcViewModel(this.resourceStrings, this.isInternetAvailable);
                window.KoHelpers = new KoHelpers();
                ko.applyBindings(vm);

                WinJS.Utilities.addClass(document.body, "pageLoaded");
                bridge.fireEvent(constants.Events.visible, true);

                // Fetch and render Learn More HTML content into the iframe.
                vm.renderLearnMoreContent();

                KoHelpers.setFocusOnAutofocusElement();
            });
        }
    });
})();

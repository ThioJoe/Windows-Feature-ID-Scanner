//
// Copyright (C) Microsoft. All rights reserved.
//
(() => {
    WinJS.UI.Pages.define("/webapps/inclusiveOobe/view/learnmore-page.html", {
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
                return result.legacy_bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "oobeHello");
            }).then((result) => {
                this.resourceStrings = JSON.parse(result);
            });

            // Fetch Learn More content from Privacy bridge
            let initializeLearnMorePromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.Privacy.getLearnMorePlainTextAsync");
            }).then((result) => {
                this.learnMoreContent = result;
            }).then(null, () => {
                this.learnMoreContent = "";
            });

            let isConnectedToNetworkPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.Environment.hasInternetAccess");
            }).then((isConnectedToNetwork) => {
                this.isInternetAvailable = isConnectedToNetwork;
            }).then(null, () => {
                this.isInternetAvailable = false;
            });

            return WinJS.Promise.join({ loadCssPromise: loadCssPromise, langAndDirPromise: langAndDirPromise, getLocalizedStringsPromise: getLocalizedStringsPromise, initializeLearnMorePromise: initializeLearnMorePromise, isConnectedToNetworkPromise: isConnectedToNetworkPromise });
        },
        error: (e) => {
            require(['legacy/bridge', 'legacy/events'], (bridge, constants) => {
                bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
            });
        },
        ready: (element, options) => {
            require(['lib/knockout', 'corejs/knockouthelpers', 'legacy/bridge', 'legacy/events', 'learnmore-vm', 'lib/knockout-winjs'], (ko, KoHelpers, bridge, constants, LearnMoreViewModel) => {
                // Apply bindings and show the page
                let vm = new LearnMoreViewModel(this.resourceStrings, this.learnMoreContent, this.isInternetAvailable);
                window.KoHelpers = new KoHelpers();
                ko.applyBindings(vm);

                WinJS.Utilities.addClass(document.body, "pageLoaded");
                bridge.fireEvent(constants.Events.visible, true);

                // Render Learn More HTML content into the iframe
                vm.renderLearnMoreContent();

                KoHelpers.setFocusOnAutofocusElement();
            });
        }
    });
})();

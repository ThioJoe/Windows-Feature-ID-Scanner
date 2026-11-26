(() => {
    "use strict";
    require.config(new RequirePathConfig('/core'));

    require(['lib/knockout', 'knockouthelpers', 'legacy/bridge', 'legacy/uiHelpers'], (ko, KoHelpers, bridge, legacy_uiHelpers) => {
        let koHelpers = new KoHelpers();
        koHelpers.registerComponents(CloudExperienceHost.RegisterComponentsScenarioMode.Default);
        window.KoHelpers = KoHelpers;

        let loadCssPromise = legacy_uiHelpers.LoadCssPromise(document.head, "", bridge);
        let langAndDirPromise = legacy_uiHelpers.LangAndDirPromise(document.documentElement, bridge);

        let getLocalizedStringsPromise = bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "oobeCommon").then((result) => {
            window.resourceStrings = JSON.parse(result); 
        });
        
        WinJS.Promise.join({ loadCssPromise, langAndDirPromise, getLocalizedStringsPromise }).done(() => {
            ko.applyBindings();
        });
    });
})();


"use strict";

(() => {
    WinJS.UI.Pages.define("/webapps/inclusiveOobe/view/autopilot/autopilotespprogress-main.html", {
        init: (element, options) => {
            require.config(new RequirePathConfig('/webapps/inclusiveOobe'));

            let getContextAndLoadCssPromise = requireAsync(['legacy/bridge']).then((result) => {
                result.legacy_bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "BootstrapStatus: Loading page context");

                return result.legacy_bridge.invoke("CloudExperienceHost.getContext");
            }).then((targetContext) => {
                let host = targetContext.host.toLowerCase();

                switch (host) {
                    case "nthaadormdm":
                    case "nthentormdm":
                    case "mosetmdmconnecttoworkprovisioningprogress":
                        this.isInOobe = false;
                        break;

                    default:
                        this.isInOobe = true;
                }

                this.targetPersonality = targetContext.personality ? targetContext.personality : CloudExperienceHost.TargetPersonality.InclusiveBlue;
            }).then(() => {
                return requireAsync(['legacy/uiHelpers', 'legacy/bridge', 'legacy/core']);
            }).then((result) => {
                if (this.isInOobe) {
                    return result.legacy_uiHelpers.LoadCssPromise(document.head, "", result.legacy_bridge);
                } else {
                    return result.legacy_uiHelpers.LoadPersonalityCssPromise(document.head, "", this.targetPersonality, result.legacy_bridge);
                }
            }).then(() => {
                if (!this.isInOobe && this.targetPersonality === CloudExperienceHost.TargetPersonality.InclusiveBlue) {
                    document.getElementById('_htmlRoot').style.background = '#004275';
                }
            });

            let langAndDirPromise = requireAsync(['legacy/uiHelpers', 'legacy/bridge']).then((result) => {
                return result.legacy_uiHelpers.LangAndDirPromise(document.documentElement, result.legacy_bridge);
            });

            let getLocalizedStringsPromise = requireAsync(['legacy/bridge', 'legacy/core']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.AutoPilot.makeAutopilotResourceObject").then((resultString) => {
                    this.resourceStrings = JSON.parse(resultString);
                }, (error) => {
                    result.legacy_bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_AutopilotEspProgressPage_FailedToLoadResource", result.legacy_core.GetJsonFromError(error));
                });
            });

            this.runProvisioning = false;

            let runProvisioningPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.AutoPilot.EnrollmentStatusPage.runProvisioningInStatusPageAsync");
            }).then((result) => {
                this.runProvisioning = (result === 1);
            });

            this.restoreMdmTasks = false;

            let restoreMdmTasksPromise = requireAsync(['legacy/bridge']).then((result) => {
                return result.legacy_bridge.invoke("CloudExperienceHost.AutoPilot.EnrollmentStatusPage.restoreMDMSyncTasks");
            }).then((result) => {
                this.restoreMdmTasks = (result === 1);
            });

            return WinJS.Promise.join({
                getContextAndLoadCssPromise: getContextAndLoadCssPromise,
                getLocalizedStringsPromise: getLocalizedStringsPromise,
                langAndDirPromise: langAndDirPromise,
                restoreMdmTasksPromise: restoreMdmTasksPromise,
                runProvisioningPromise: runProvisioningPromise
            });
        },

        error: (e) => {
            require(['legacy/bridge', 'legacy/events'], (bridge, constants) => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot enrollment status page failed to load", JSON.stringify({ error: e }));
                bridge.fireEvent(constants.Events.done, constants.AppResult.error);
            });
        },

        ready: (element, options) => {
            require(
                [
                    'lib/knockout', 
                    'corejs/knockouthelpers', 
                    'legacy/bridge',
                    'legacy/events',
                    'autopilot/autopilotespprogress-vm',
                    'autopilot/bootstrapSessionGeneralUtilities',
                    this.targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite ? 'autopilot/bootstrapStatusCategoryView-lite' : 'autopilot/bootstrapStatusCategoryView',
                    'autopilot/devicePreparationCategoryViewModel',
                    'autopilot/deviceSetupCategoryViewModel',
                    'autopilot/accountSetupCategoryViewModel'
                ],
                (
                    ko,
                    koHelpers,
                    bridge,
                    constants,
                    autopilotEspProgressViewModel,
                    bootstrapSessionGeneralUtilities,
                    bootstrapStatusCategoryView,
                    devicePreparationCategoryViewModel,
                    deviceSetupCategoryViewModel,
                    accountSetupCategoryViewModel) => {

                    this.sessionUtilities = new bootstrapSessionGeneralUtilities(this.isInOobe);

                    this.sessionUtilities.storeSettingAsync(
                        this.sessionUtilities.STATE_NAME_GLOBAL_RUN_PROVISIONING,
                        this.runProvisioning ? "true" : "false");

                    this.sessionUtilities.storeSettingAsync(
                        this.sessionUtilities.STATE_NAME_GLOBAL_RESTORE_MDM_TASKS,
                        this.restoreMdmTasks ? "true" : "false");

                    this.sessionUtilities.storeSettingAsync(
                        this.sessionUtilities.STATE_NAME_GLOBAL_MDM_ENROLLMENT_STATUS,
                        this.sessionUtilities.MDM_ENROLLMENT_DISPOSITION[EnterpriseDeviceManagement.Service.AutoPilot.EnrollmentDisposition.unknown]);

                    let categoryRegistrations = [
                        devicePreparationCategoryViewModel,
                        deviceSetupCategoryViewModel,
                        accountSetupCategoryViewModel
                    ];
                        
                    let koPageHelpers = new koHelpers();
                    koPageHelpers.registerComponents(CloudExperienceHost.RegisterComponentsScenarioMode.LightProgress, true /*holdForAdditionalRegistration*/);
                    koPageHelpers.registerComponents(CloudExperienceHost.RegisterComponentsScenarioMode.InclusiveOobe);
                    window.KoHelpers = koHelpers;

                    let categoriesTable = element.querySelector((this.targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite) ? "#categoriesTableLite" : "#categoriesTable");

                    if (this.targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite)
                    {
                        categoriesTable.setAttribute("width", "100%");
                        categoriesTable.setAttribute("display", "flex");
                        categoriesTable.setAttribute("justify-content", "center");
                    }

                    let categoryViews = [];
                    let categoryViewInitializationPromises = [];

                    for (let i = 0; i < categoryRegistrations.length; i++) {
                        categoryViews.push(new bootstrapStatusCategoryView(
                            this.resourceStrings,
                            this.sessionUtilities,
                            categoriesTable,
                            new categoryRegistrations[i](
                                this.resourceStrings,
                                this.sessionUtilities)));

                        let currentInitializationPromise = categoryViews[i].getInitializationPromise();
                        if (currentInitializationPromise !== null) {
                            categoryViewInitializationPromises.push(currentInitializationPromise);
                        }

                        if (this.targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite)
                        {
                            categoriesTable.appendChild(categoryViews[i].getCategoryBody());
                        }
                    }

                    let vm = new autopilotEspProgressViewModel(
                        this.resourceStrings,
                        this.targetPersonality,
                        this.sessionUtilities,
                        categoryViews,
                        categoryViewInitializationPromises);

                    ko.applyBindings(vm);

                    KoHelpers.waitForInitialComponentLoadAsync().then(() => {
                        WinJS.Utilities.addClass(document.body, "pageLoaded");
                        bridge.fireEvent(constants.Events.visible, true);
                        KoHelpers.setFocusOnAutofocusElement();
                    });
            });
        }
    });
})();

//
// Copyright (C) Microsoft. All rights reserved.
//
/// <disable>JS2085.EnableStrictMode</disable>
"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    class TargetEnvironment {
    }
    TargetEnvironment.PROD = "CloudExperienceHost.Environment.PROD";
    TargetEnvironment.INT = "CloudExperienceHost.Environment.INT";
    CloudExperienceHost.TargetEnvironment = TargetEnvironment;
    // TargetPlatform class creates friendly names for a subset of DEVICEFAMILYINFOENUM_* 
    // that can be returned by Environment getPlatform.
    // New additions to this enum can be made if/when we need a friendly name to reference in 
    // CXH SystemApp code, but the assigned string value must match the programmatic format
    // "CloudExperienceHost.Platform.[decimal number]" generated in Environment.ts
    // from the nturtl.w enum values.
    class TargetPlatform {
    }
    TargetPlatform.DESKTOP = "CloudExperienceHost.Platform.DESKTOP";
    TargetPlatform.MOBILE = "CloudExperienceHost.Platform.MOBILE";
    TargetPlatform.XBOX = "CloudExperienceHost.Platform.XBOX";
    TargetPlatform.HOLOGRAPHIC = "CloudExperienceHost.Platform.HOLOGRAPHIC";
    TargetPlatform.SURFACEHUB = "CloudExperienceHost.Platform.SURFACEHUB";
    // Below this point (non-legacy TargetPlatform values), if friendly names are required for CXH app code
    // they should be defined in alignment with the "CloudExperienceHost.Platform."+(nturtl enum value)
    // per CloudExperienceHost::Environment::getPlatform()
    TargetPlatform.WINDOWS8828080 = "CloudExperienceHost.Platform.14";
    TargetPlatform.WINDOWSCORE = "CloudExperienceHost.Platform.16";
    CloudExperienceHost.TargetPlatform = TargetPlatform;
    class TargetPersonality {
    }
    TargetPersonality.Unspecified = "CloudExperienceHost.Personality.Unspecified";
    TargetPersonality.InclusiveBlue = "CloudExperienceHost.Personality.InclusiveBlue";
    TargetPersonality.LiteWhite = "CloudExperienceHost.Personality.LiteWhite";
    CloudExperienceHost.TargetPersonality = TargetPersonality;
    let FrameViewModelUpdateType;
    (function (FrameViewModelUpdateType) {
        FrameViewModelUpdateType[FrameViewModelUpdateType["Progress"] = 1] = "Progress";
        FrameViewModelUpdateType[FrameViewModelUpdateType["View"] = 2] = "View";
        FrameViewModelUpdateType[FrameViewModelUpdateType["Dimmed"] = 3] = "Dimmed";
        FrameViewModelUpdateType[FrameViewModelUpdateType["Undimmed"] = 4] = "Undimmed";
        FrameViewModelUpdateType[FrameViewModelUpdateType["Language"] = 5] = "Language";
        FrameViewModelUpdateType[FrameViewModelUpdateType["InputSwitchButton"] = 6] = "InputSwitchButton";
        FrameViewModelUpdateType[FrameViewModelUpdateType["ResetFooterFocus"] = 7] = "ResetFooterFocus";
        FrameViewModelUpdateType[FrameViewModelUpdateType["GraphicAnimation"] = 8] = "GraphicAnimation";
        FrameViewModelUpdateType[FrameViewModelUpdateType["UpdateTransitionMessage"] = 9] = "UpdateTransitionMessage";
    })(FrameViewModelUpdateType = CloudExperienceHost.FrameViewModelUpdateType || (CloudExperienceHost.FrameViewModelUpdateType = {}));
    let NavigationEvent;
    (function (NavigationEvent) {
        NavigationEvent[NavigationEvent["CompletedAndVisible"] = 1] = "CompletedAndVisible";
        NavigationEvent[NavigationEvent["LastWebAppFinished"] = 2] = "LastWebAppFinished";
    })(NavigationEvent = CloudExperienceHost.NavigationEvent || (CloudExperienceHost.NavigationEvent = {}));
    let LocalErrorHandlingMode;
    (function (LocalErrorHandlingMode) {
        LocalErrorHandlingMode[LocalErrorHandlingMode["LocalErrorHandlingEnabled"] = 1] = "LocalErrorHandlingEnabled";
        LocalErrorHandlingMode[LocalErrorHandlingMode["LocalErrorHandlingEnabledForKnownErrors"] = 2] = "LocalErrorHandlingEnabledForKnownErrors";
        LocalErrorHandlingMode[LocalErrorHandlingMode["LocalErrorhandlingDisabled"] = 3] = "LocalErrorhandlingDisabled";
    })(LocalErrorHandlingMode = CloudExperienceHost.LocalErrorHandlingMode || (CloudExperienceHost.LocalErrorHandlingMode = {}));
    let RegisterComponentsScenarioMode;
    (function (RegisterComponentsScenarioMode) {
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["Default"] = 1] = "Default";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["InclusiveOobe"] = 2] = "InclusiveOobe";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["Scoobe"] = 3] = "Scoobe";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["AOobe"] = 4] = "AOobe";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["LightProgress"] = 5] = "LightProgress";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["LightFooter"] = 6] = "LightFooter";
    })(RegisterComponentsScenarioMode = CloudExperienceHost.RegisterComponentsScenarioMode || (CloudExperienceHost.RegisterComponentsScenarioMode = {}));
    class WinRtErrorWrapper {
        constructor(error) {
            this.error = error;
        }
        toJSON() {
            if (this.error.detail) {
                var data = this.error.detail;
                var logData = {
                    errorCode: data && (data.number || (data.exception && (data.exception.number || data.exception.code)) || (data.error && data.error.number) || data.errorCode || 0),
                    message: data && (data.message || data.errorMessage || (data.error && data.error.message) || (data.exception && data.exception.message) || null),
                    stack: data && (data.stack || (data.exception && (data.exception.stack || data.exception.message)) || (data.error && data.error.stack) || null)
                };
                return JSON.stringify(logData);
            }
            if (this.error.number) {
                Object.defineProperty(this.error, 'number', { enumerable: true });
            }
            if (this.error.description) {
                Object.defineProperty(this.error, 'description', { enumerable: true });
            }
            if (this.error.message) {
                Object.defineProperty(this.error, 'message', { enumerable: true });
            }
            if (this.error.stack) {
                Object.defineProperty(this.error, 'stack', { enumerable: true });
            }
            if (this.error.asyncOpSource && this.error.asyncOpSource.stack) {
                Object.defineProperty(this.error.asyncOpSource, 'stack', { enumerable: true });
            }
            return JSON.stringify(this.error);
        }
    }
    CloudExperienceHost.WinRtErrorWrapper = WinRtErrorWrapper;
    function GetJsonFromError(error) {
        var errWrapper = new WinRtErrorWrapper(error);
        let json;
        try {
            json = JSON.stringify(errWrapper);
        }
        catch (ex) {
            // This is a safeguard against any non-stringifiable errors (e.g. unexpected WinRT objects)
            json = JSON.stringify({ message: "GetJsonFromError failed to stringify error object", originalErrorNumber: error && error.number });
        }
        return json;
    }
    CloudExperienceHost.GetJsonFromError = GetJsonFromError;
    function AddCssToHead(head, fileName) {
        var fileRef = head.ownerDocument.createElement("link");
        fileRef.setAttribute("rel", "stylesheet");
        fileRef.setAttribute("type", "text/css");
        fileRef.setAttribute("href", fileName);
        head.appendChild(fileRef);
    }
    CloudExperienceHost.AddCssToHead = AddCssToHead;
    function GetCssList(appRoot, context) {
        var uiDarkCss = appRoot + "/Microsoft.WinJS-reduced/css/ui-dark.css";
        var uiLightCss = appRoot + "/Microsoft.WinJS-reduced/css/ui-light.css";
        var oobeDesktopCss = appRoot + "/css/oobe-desktop.css";
        var inclusiveOobeDesktopCss = appRoot + "/css/inclusiveoobe-desktop.css";
        var oobeACss = appRoot + "/css/oobe-A.css";
        var oobeHubOSCss = appRoot + "/css/oobe-HubOS.css";
        var oobeMobileCss = appRoot + "/css/oobe-mobile.css";
        var settingsDesktopCss = appRoot + "/css/settings-desktop.css";
        var settingsMobileCss = appRoot + "/css/settings-mobile.css";
        var xboxCss = appRoot + "/css/xbox.css";
        var xboxDarkCss = appRoot + "/css/xbox-ui-dark.css";
        var xboxLightCss = appRoot + "/css/xbox-ui-light.css";
        var surfaceHubCss = appRoot + "/css/oobe-desktop.css";
        var hololensCss = appRoot + "/css/hololens.css";
        var oobeLightCss = appRoot + "/css/oobe-light.css";
        var desktopOOBECssList = [uiDarkCss, oobeDesktopCss];
        var inclusiveDesktopOOBECssList = [uiDarkCss, inclusiveOobeDesktopCss];
        var AOOBECssList = [uiLightCss, oobeACss];
        var mobileOOBECssList = [uiDarkCss, oobeMobileCss];
        var desktopSettingsCssList = [uiLightCss, settingsDesktopCss];
        var mobileSettingsCssList = [uiDarkCss, settingsMobileCss];
        var xboxDarkCssList = [uiDarkCss, xboxDarkCss, xboxCss];
        var xboxLightCssList = [uiLightCss, xboxLightCss, xboxCss];
        var surfaceHubCssList = [uiDarkCss, surfaceHubCss];
        var hololensCssList = [uiDarkCss, hololensCss];
        var hubOSOOBECssList = [uiDarkCss, oobeHubOSCss];
        var liteOobeCssList = [uiLightCss, oobeLightCss];
        // Lookup type 1: Direct scenario overrides of csslist
        // (No additional complexity / differentiation, as the benefit of legacy-style platform+scenario differentiation
        //  is largely removed by CShell and product-family convergence.
        //  This is primarily to support scenario who've added custom css files to augment their Scenario-json Personality)
        switch (context.experienceName) {
            case "FRXSURFACEHUB2":
                return hubOSOOBECssList;
            default:
                break;
        }
        // Lookup type 2: Determined by the Scenario Personality value in json definition
        // Scenarios tagged with Personality directly use corresponding css list
        switch (context.personality) {
            case CloudExperienceHost.TargetPersonality.InclusiveBlue:
                return inclusiveDesktopOOBECssList;
            case CloudExperienceHost.TargetPersonality.LiteWhite:
                return liteOobeCssList;
            default:
                break;
        }
        // Lookup type 3: Use legacy platform/scenario lookup behavior for untagged cases
        // New Scenarios should usually not be added here since tagged Personality at scenario authorship is expected to provide the correct csslist lookup
        var cssLookupTable = new Object();
        cssLookupTable[TargetPlatform.DESKTOP] = {
            "DEFAULT": desktopSettingsCssList,
            "FRX": desktopOOBECssList,
            "FRXAAD": desktopOOBECssList,
            "FRXRDX": desktopOOBECssList,
            "FRXRDXINCLUSIVE": inclusiveDesktopOOBECssList,
            "LOCALONLY": desktopOOBECssList,
            "NTH": desktopOOBECssList,
            "NTHAAD": desktopOOBECssList,
            "NTHAADNGCFIXME": desktopOOBECssList,
            "NTHAADNGCONLY": desktopOOBECssList,
            "NTHAADNGCRESET": desktopOOBECssList,
            "NTHAADRECOVERY": desktopSettingsCssList,
            "NTHENT": desktopOOBECssList,
            "NTHENTORMDM": desktopOOBECssList,
            "NTHAADORMDM": desktopOOBECssList,
            "NTHENTNGCFIXME": desktopOOBECssList,
            "NTHENTNGCONLY": desktopOOBECssList,
            "NTHENTNGCRESET": desktopOOBECssList,
            "NTHMSA": desktopOOBECssList,
            "NTHNGCUPSELL": desktopOOBECssList,
            "RDXPOSTOOBE": desktopOOBECssList,
            "RDXPOSTOOBEINCLUSIVE": inclusiveDesktopOOBECssList,
            "RDXRACSKU": desktopOOBECssList,
            "RDXRACSKUINCLUSIVE": inclusiveDesktopOOBECssList,
            "FRXSURFACEHUB": surfaceHubCssList,
            "INCLUSIVETEST": desktopOOBECssList,
            "ATEST": AOOBECssList,
            "MSACFLPINRESET": desktopOOBECssList,
            "MSACFLPINRESETSIGNIN": inclusiveDesktopOOBECssList,
            "MSASSPR": inclusiveDesktopOOBECssList,
            "AADPINRESETAUTH": inclusiveDesktopOOBECssList,
            "AADSSPR": inclusiveDesktopOOBECssList,
            "AADSSPRV2": inclusiveDesktopOOBECssList,
            "AADWEBAUTH": desktopOOBECssList,
            "MOSETMDMCONNECTTOWORKPROVISIONINGPROGRESS": inclusiveDesktopOOBECssList,
        };
        cssLookupTable[TargetPlatform.MOBILE] = {
            "DEFAULT": mobileOOBECssList,
            "MOSETCONNECTTOWORK": mobileSettingsCssList,
            "MOSETMDMCONNECTTOWORK": mobileSettingsCssList,
            "MOSETMAMCONNECTTOWORK": mobileSettingsCssList,
            "MOSET": mobileSettingsCssList,
        };
        cssLookupTable[TargetPlatform.XBOX] = {
            "DEFAULT": xboxDarkCssList,
            "DEFAULTDARK": xboxDarkCssList,
            "DEFAULTLIGHT": xboxLightCssList,
        };
        cssLookupTable[TargetPlatform.HOLOGRAPHIC] = {
            "DEFAULT": hololensCssList,
            "AADWEBAUTH": desktopOOBECssList,
        };
        cssLookupTable[TargetPlatform.SURFACEHUB] = {
            "DEFAULT": surfaceHubCssList,
            "SURFACEHUBSETADDDEVICEUSER": desktopSettingsCssList,
            "AADWEBAUTH": desktopOOBECssList,
        };
        cssLookupTable["OtherPlatform"] = {
            "DEFAULT": desktopSettingsCssList,
            "FRXOOBEA": AOOBECssList,
        };
        var platform = context.platform;
        var host = context.host.toUpperCase();
        var cssList = null;
        // There is no longer a catch-all bucket value in TargetPlatform enumeration
        // Define a fallback csslist lookup for non-targetable platforms.
        if (!cssLookupTable.hasOwnProperty(platform)) {
            platform = "OtherPlatform";
        }
        // For uri "ms-cxh://frx/inclusive", host = frx and experienceName = frxinclusive.
        cssList = cssLookupTable[platform][context.experienceName];
        if (!cssList) {
            cssList = cssLookupTable[platform][host];
            // If this is Xbox, figure out if we should be using the light or dark theme.  If our call to
            // defaultSystemTheme goes off the rails or returns something unexpected, fall through to the
            // DEFAULT css list, which happens to be dark.
            if (!cssList && (platform == TargetPlatform.XBOX)) {
                try {
                    var theme = Windows.Xbox.System.Internal.Personalization.SystemPersonalization.defaultSystemTheme;
                    if (theme == Windows.Xbox.System.Internal.Personalization.SystemTheme.light) {
                        cssList = cssLookupTable[platform]["DEFAULTLIGHT"];
                    }
                    else if (theme == Windows.Xbox.System.Internal.Personalization.SystemTheme.dark) {
                        cssList = cssLookupTable[platform]["DEFAULTDARK"];
                    }
                }
                catch (e) {
                }
            }
            if (!cssList) {
                cssList = cssLookupTable[platform]["DEFAULT"];
            }
        }
        return cssList;
    }
    CloudExperienceHost.GetCssList = GetCssList;
})(CloudExperienceHost || (CloudExperienceHost = {}));
// Expose css functions to be loaded by requirejs
if ((typeof define === "function") && define.amd) {
    define(function () {
        return {
            GetCssList: function (appRoot, context) {
                return CloudExperienceHost.GetCssList(appRoot, context);
            },
            AddCssToHead: function (head, fileName) {
                CloudExperienceHost.AddCssToHead(head, fileName);
            },
            WinRtErrorWrapper: CloudExperienceHost.WinRtErrorWrapper,
            GetJsonFromError: CloudExperienceHost.GetJsonFromError
        };
    });
}
//# sourceMappingURL=core.js.map
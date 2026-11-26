"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    class TargetEnvironment {
    }
    TargetEnvironment.PROD = "CloudExperienceHost.Environment.PROD";
    TargetEnvironment.INT = "CloudExperienceHost.Environment.INT";
    CloudExperienceHost.TargetEnvironment = TargetEnvironment;
    class TargetPlatform {
    }
    TargetPlatform.DESKTOP = "CloudExperienceHost.Platform.DESKTOP";
    TargetPlatform.MOBILE = "CloudExperienceHost.Platform.MOBILE";
    TargetPlatform.XBOX = "CloudExperienceHost.Platform.XBOX";
    TargetPlatform.SERVER = "CloudExperienceHost.Platform.SERVER";
    TargetPlatform.HOLOGRAPHIC = "CloudExperienceHost.Platform.HOLOGRAPHIC";
    TargetPlatform.SURFACEHUB = "CloudExperienceHost.Platform.SURFACEHUB";
    TargetPlatform.WINDOWS8828080 = "CloudExperienceHost.Platform.14";
    TargetPlatform.WINDOWSCORE = "CloudExperienceHost.Platform.16";
    CloudExperienceHost.TargetPlatform = TargetPlatform;
    class TargetDevice {
    }
    TargetDevice.UNKNOWN = 0x00000000; // DEVICEFAMILYDEVICEFORM_UNKNOWN
    TargetDevice.HANDHELD = 0x0000002E; // DEVICEFAMILYDEVICEFORM_GAMING_HANDHELD
    CloudExperienceHost.TargetDevice = TargetDevice;
    class TargetPersonality {
    }
    TargetPersonality.Unspecified = "CloudExperienceHost.Personality.Unspecified";
    TargetPersonality.InclusiveBlue = "CloudExperienceHost.Personality.InclusiveBlue";
    TargetPersonality.LiteWhite = "CloudExperienceHost.Personality.LiteWhite";
    CloudExperienceHost.TargetPersonality = TargetPersonality;
    (function (FrameViewModelUpdateType) {
        FrameViewModelUpdateType[FrameViewModelUpdateType["Progress"] = 1] = "Progress";
        FrameViewModelUpdateType[FrameViewModelUpdateType["View"] = 2] = "View";
        FrameViewModelUpdateType[FrameViewModelUpdateType["Dimmed"] = 3] = "Dimmed";
        FrameViewModelUpdateType[FrameViewModelUpdateType["Undimmed"] = 4] = "Undimmed";
        FrameViewModelUpdateType[FrameViewModelUpdateType["Language"] = 5] = "Language";
        FrameViewModelUpdateType[FrameViewModelUpdateType["UpdateDirection"] = 6] = "UpdateDirection";
        FrameViewModelUpdateType[FrameViewModelUpdateType["InputSwitchButton"] = 7] = "InputSwitchButton";
        FrameViewModelUpdateType[FrameViewModelUpdateType["ResetFooterFocus"] = 8] = "ResetFooterFocus";
        FrameViewModelUpdateType[FrameViewModelUpdateType["GraphicAnimation"] = 9] = "GraphicAnimation";
        FrameViewModelUpdateType[FrameViewModelUpdateType["UpdateTransitionMessage"] = 10] = "UpdateTransitionMessage";
        FrameViewModelUpdateType[FrameViewModelUpdateType["SetDisplayModeFullScreen"] = 11] = "SetDisplayModeFullScreen";
        FrameViewModelUpdateType[FrameViewModelUpdateType["SetBackgroundImage"] = 12] = "SetBackgroundImage";
        FrameViewModelUpdateType[FrameViewModelUpdateType["GamepadLegendB"] = 13] = "GamepadLegendB";
    })(CloudExperienceHost.FrameViewModelUpdateType || (CloudExperienceHost.FrameViewModelUpdateType = {}));
    var FrameViewModelUpdateType = CloudExperienceHost.FrameViewModelUpdateType;
    (function (NavigationEvent) {
        NavigationEvent[NavigationEvent["CompletedAndVisible"] = 1] = "CompletedAndVisible";
        NavigationEvent[NavigationEvent["LastWebAppFinished"] = 2] = "LastWebAppFinished";
    })(CloudExperienceHost.NavigationEvent || (CloudExperienceHost.NavigationEvent = {}));
    var NavigationEvent = CloudExperienceHost.NavigationEvent;
    (function (LocalErrorHandlingMode) {
        LocalErrorHandlingMode[LocalErrorHandlingMode["LocalErrorHandlingEnabled"] = 1] = "LocalErrorHandlingEnabled";
        LocalErrorHandlingMode[LocalErrorHandlingMode["LocalErrorHandlingEnabledForKnownErrors"] = 2] = "LocalErrorHandlingEnabledForKnownErrors";
        LocalErrorHandlingMode[LocalErrorHandlingMode["LocalErrorhandlingDisabled"] = 3] = "LocalErrorhandlingDisabled";
    })(CloudExperienceHost.LocalErrorHandlingMode || (CloudExperienceHost.LocalErrorHandlingMode = {}));
    var LocalErrorHandlingMode = CloudExperienceHost.LocalErrorHandlingMode;
    (function (RegisterComponentsScenarioMode) {
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["Default"] = 1] = "Default";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["InclusiveOobe"] = 2] = "InclusiveOobe";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["Scoobe"] = 3] = "Scoobe";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["AOobe"] = 4] = "AOobe";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["LightProgress"] = 5] = "LightProgress";
        RegisterComponentsScenarioMode[RegisterComponentsScenarioMode["LightFooter"] = 6] = "LightFooter";
    })(CloudExperienceHost.RegisterComponentsScenarioMode || (CloudExperienceHost.RegisterComponentsScenarioMode = {}));
    var RegisterComponentsScenarioMode = CloudExperienceHost.RegisterComponentsScenarioMode;
    class RedirectEventArgs {
        constructor(url, key = null, value = null, httpMethod = "GET") {
            this.url = url;
            this.key = key;
            this.value = value;
            this.httpMethod = httpMethod;
        }
    }
    CloudExperienceHost.RedirectEventArgs = RedirectEventArgs;
    class UserInfo {
        constructor() {
            this.firstName = null;
            this.lastName = null;
            this.email = null;
            this.country = null;
        }
    }
    CloudExperienceHost.UserInfo = UserInfo;
    class GetTicketEventArgs {
        constructor(targetUrl, policy, errorUrl) {
            this.targetUrl = targetUrl;
            this.policy = policy;
            this.errorUrl = errorUrl;
            this.ticketRequestId = "";
            this.msaTicketBroker = false;
        }
    }
    CloudExperienceHost.GetTicketEventArgs = GetTicketEventArgs;
    class ShowEaseOfAccessArgs {
        constructor(rect) {
            this.left = rect.left;
            this.top = rect.top;
            this.right = rect.right;
            this.bottom = rect.bottom;
        }
    }
    CloudExperienceHost.ShowEaseOfAccessArgs = ShowEaseOfAccessArgs;
    class ResourceManager {
        static GetContentAndAccesskey(localString) {
            if (typeof localString !== 'undefined') {
                var pattern = '&(?! )'; // Regex for & not followed by a space
                var index = localString.search(pattern);
                if ((index > -1) && (index < (localString.length - 1))) {
                    return { 'content': (localString.substring(0, index) + localString.substring(index + 1)), 'accessKey': localString.charAt(index + 1) };
                }
            }
            return { 'content': localString, 'accessKey': '' };
        }
    }
    CloudExperienceHost.ResourceManager = ResourceManager;
    class UriHelper {
        static RemovePIIFromUri(uri) {
            return (uri ? (uri.split('#')[0]).split('?')[0] : null);
        }
    }
    CloudExperienceHost.UriHelper = UriHelper;
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
        var liteOobeCssList = [uiLightCss, oobeLightCss];
        switch (context.personality) {
            case CloudExperienceHost.TargetPersonality.InclusiveBlue:
                return inclusiveDesktopOOBECssList;
            case CloudExperienceHost.TargetPersonality.LiteWhite:
                return liteOobeCssList;
            default:
                break;
        }
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
            "NTHEXPEDITEDUPDATE": desktopSettingsCssList,
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
        cssLookupTable[TargetPlatform.SERVER] = {
            "DEFAULT": desktopSettingsCssList,
            "FRX": desktopOOBECssList,
            "FRXAAD": desktopOOBECssList,
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
            "MSACFLPINRESET": desktopOOBECssList,
            "MSACFLPINRESETSIGNIN": inclusiveDesktopOOBECssList,
            "MSASSPR": inclusiveDesktopOOBECssList,
            "AADPINRESETAUTH": inclusiveDesktopOOBECssList,
            "AADSSPR": inclusiveDesktopOOBECssList,
            "AADSSPRV2": inclusiveDesktopOOBECssList,
            "AADWEBAUTH": desktopOOBECssList,
            "MOSETMDMCONNECTTOWORKPROVISIONINGPROGRESS": inclusiveDesktopOOBECssList,
            "NTHEXPEDITEDUPDATE": desktopSettingsCssList,
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
        if (!cssLookupTable.hasOwnProperty(platform)) {
            platform = "OtherPlatform";
        }
        cssList = cssLookupTable[platform][context.experienceName];
        if (!cssList) {
            cssList = cssLookupTable[platform][host];
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

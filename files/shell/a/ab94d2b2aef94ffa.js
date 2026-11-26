"use strict";
var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator.throw(value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : new P(function (resolve) { resolve(result.value); }).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments)).next());
    });
};
var CloudExperienceHost;
(function (CloudExperienceHost) {
    class MSA {
        static getDefaultAccountTokenSilentlyAsync(callerUri, requestJson) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch) {
                return __awaiter(this, void 0, void 0, function* () {
                    try {
                        let responseObject = {
                            responsestatus: "",
                            token: "",
                            properties: "",
                            errorMessage: "",
                            errorCode: ""
                        };
                        if (!CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("GetDefaultAccountTokenCXHHelper")) {
                            responseObject.errorMessage = "FeatureIsDisabled";
                            responseObject.errorCode = "2147780800"; // PPCRL_REQUEST_E_FEATURE_NOT_SUPPORTED
                            errorDispatch(responseObject);
                            return;
                        }
                        let parsedRequest = JSON.parse(requestJson);
                        let provider = parsedRequest.provider;
                        let scope = parsedRequest.scope;
                        let clientId = parsedRequest.clientId;
                        let authority = parsedRequest.authority;
                        let propertiesObj = parsedRequest.webtokenrequestproperties;
                        let accountProvider = yield Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager.findAccountProviderAsync(provider, authority);
                        if (accountProvider) {
                            let isFeatureSupportedScope = ""; // empty string for is feature supported scope.
                            let isFeatureSupportedTokenRequest = new Windows.Security.Authentication.Web.Core.WebTokenRequest(accountProvider, isFeatureSupportedScope);
                            isFeatureSupportedTokenRequest.properties.insert("IsFeatureSupported", "CxhWamTokenAcquisition");
                            let isFeatureSupportedTokenResponse = yield Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager.getTokenSilentlyAsync(isFeatureSupportedTokenRequest);
                            if (isFeatureSupportedTokenResponse) {
                                if (isFeatureSupportedTokenResponse.responseStatus == Windows.Security.Authentication.Web.Core.WebTokenRequestStatus.success) {
                                    let webPageUriKey = "web_page_uri";
                                    let tokenRequest = new Windows.Security.Authentication.Web.Core.WebTokenRequest(accountProvider, scope, clientId);
                                    for (let key in propertiesObj) {
                                        if (key !== webPageUriKey) {
                                            tokenRequest.properties.insert(key, propertiesObj[key]);
                                        }
                                    }
                                    if (callerUri) {
                                        tokenRequest.properties.insert(webPageUriKey, callerUri);
                                    }
                                    else {
                                        responseObject.errorMessage = "EmptyCallerUri";
                                        responseObject.errorCode = "2147780799"; // PPCRL_REQUEST_E_WEB_PAGE_URI_MISSING
                                        CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("getDefaultAccountTokenSilentlyAsync", JSON.stringify({ errorMessage: responseObject.errorMessage, errorCode: responseObject.errorCode }));
                                        errorDispatch(responseObject);
                                        return;
                                    }
                                    let tokenResponse = yield Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager.getTokenSilentlyAsync(tokenRequest);
                                    if (tokenResponse) {
                                        responseObject.responsestatus = tokenResponse.responseStatus.toString();
                                        if (tokenResponse.responseStatus == Windows.Security.Authentication.Web.Core.WebTokenRequestStatus.success) {
                                            if (tokenResponse.responseData[0]) {
                                                responseObject.token = tokenResponse.responseData[0].token;
                                                try {
                                                    if (tokenResponse.responseData[0].properties) {
                                                        responseObject.properties = JSON.stringify(tokenResponse.responseData[0].properties);
                                                    }
                                                }
                                                catch (ex) {
                                                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("failed to get response properties in getDefaultAccountTokenSilentlyAsync", CloudExperienceHost.GetJsonFromError(ex));
                                                }
                                                completeDispatch(responseObject);
                                            }
                                            else {
                                                responseObject.errorMessage = "NoTokenFound";
                                                responseObject.errorCode = "1008"; // ERROR_NO_TOKEN
                                                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("getDefaultAccountTokenSilentlyAsync", JSON.stringify({ errorMessage: responseObject.errorMessage, errorCode: responseObject.errorCode }));
                                                errorDispatch(responseObject);
                                            }
                                        }
                                        else {
                                            responseObject.responsestatus = tokenResponse.responseStatus.toString();
                                            responseObject.errorMessage = tokenResponse.responseError.errorMessage;
                                            responseObject.errorCode = tokenResponse.responseError.errorCode.toString();
                                            try {
                                                if (tokenResponse.responseError.properties) {
                                                    responseObject.properties = JSON.stringify(tokenResponse.responseError.properties);
                                                }
                                            }
                                            catch (ex) {
                                                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("failed to get error properties in getDefaultAccountTokenSilentlyAsync", CloudExperienceHost.GetJsonFromError(ex));
                                            }
                                            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("getDefaultAccountTokenSilentlyAsync", JSON.stringify({ responsestatus: responseObject.responsestatus, errorMessage: responseObject.errorMessage, errorCode: responseObject.errorCode }));
                                            errorDispatch(responseObject);
                                        }
                                    }
                                    else {
                                        responseObject.errorMessage = "NoTokenResponses";
                                        responseObject.errorCode = "660"; // ERROR_NO_RESPONSES
                                        CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("getDefaultAccountTokenSilentlyAsync", JSON.stringify({ errorMessage: responseObject.errorMessage, errorCode: responseObject.errorCode }));
                                        errorDispatch(responseObject);
                                    }
                                }
                                else {
                                    responseObject.responsestatus = isFeatureSupportedTokenResponse.responseStatus.toString();
                                    responseObject.errorMessage = isFeatureSupportedTokenResponse.responseError.errorMessage;
                                    responseObject.errorCode = isFeatureSupportedTokenResponse.responseError.errorCode.toString();
                                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("getDefaultAccountTokenSilentlyAsync", JSON.stringify({ responsestatus: responseObject.responsestatus, errorMessage: responseObject.errorMessage, errorCode: responseObject.errorCode }));
                                    errorDispatch(responseObject);
                                }
                            }
                            else {
                                responseObject.errorMessage = "FeatureRequestNoTokenResponses";
                                responseObject.errorCode = "660"; // ERROR_NO_RESPONSES
                                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("getDefaultAccountTokenSilentlyAsync", JSON.stringify({ errorMessage: responseObject.errorMessage, errorCode: responseObject.errorCode }));
                                errorDispatch(responseObject);
                            }
                        }
                        else {
                            responseObject.responsestatus = Windows.Security.Authentication.Web.Core.WebTokenRequestStatus.accountProviderNotAvailable.toString();
                            responseObject.errorMessage = "AccountProviderNotAvailable";
                            responseObject.errorCode = "3400204291"; // ERROR_ADAL_ACCOUNT_PROVIDER_NOT_AVAILABLE 0xcaab0003
                            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("getDefaultAccountTokenSilentlyAsync", JSON.stringify({ responsestatus: responseObject.responsestatus, errorMessage: responseObject.errorMessage, errorCode: responseObject.errorCode }));
                            errorDispatch(responseObject);
                        }
                    }
                    catch (ex) {
                        CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("getDefaultAccountTokenSilentlyAsync", CloudExperienceHost.GetJsonFromError(ex));
                        errorDispatch(ex);
                    }
                });
            });
        }
    }
    __decorate([
        CloudExperienceHost.BridgeHelpers.requireCallerUri,
        CloudExperienceHost.BridgeHelpers.validateCallbackUri
    ], MSA, "getDefaultAccountTokenSilentlyAsync", null);
    CloudExperienceHost.MSA = MSA;
    (function (MSA) {
        var Crypto = Windows.Security.Cryptography;
        let _userInfo = null;
        let _persistedMsaExtension = null;
        let _verificationCode;
        function createConnectedAccount(data, encodedPassword, daToken, creation, expiry, sessionKey, flowToken) {
            let passwordBuffer = null;
            let daTokenBuffer = null;
            let sessionKeyBuffer = null;
            let platform = CloudExperienceHost.Environment.getPlatform();
            let platformIsWindowsCore = (platform == CloudExperienceHost.TargetPlatform.WINDOWS8828080) || (platform == CloudExperienceHost.TargetPlatform.WINDOWSCORE);
            let enableAutologon = false;
            if (typeof (data) == "string") {
                if (encodedPassword) {
                    passwordBuffer = Crypto.CryptographicBuffer.decodeFromBase64String(encodedPassword);
                }
                if (daToken) {
                    daTokenBuffer = Crypto.CryptographicBuffer.convertStringToBinary(daToken, Crypto.BinaryStringEncoding.utf8);
                }
                if (sessionKey) {
                    sessionKeyBuffer = Crypto.CryptographicBuffer.convertStringToBinary(sessionKey, Crypto.BinaryStringEncoding.utf8);
                }
                let extension = getBrokeredExtension();
                let platformIsHolographic = (platform == CloudExperienceHost.TargetPlatform.HOLOGRAPHIC);
                let setDeviceOwner = platformIsWindowsCore || platformIsHolographic;
                return extension.createConnectedAccountAsync(data, passwordBuffer, daTokenBuffer, creation, expiry, sessionKeyBuffer, flowToken, enableAutologon, setDeviceOwner).then((userId) => {
                    CloudExperienceHost.IUserManager.getInstance().setIUserFromId(userId.toString());
                    CloudExperienceHost.IUserManager.getInstance().setSignInIdentityProvider(CloudExperienceHostAPI.SignInIdentityProviders.msa);
                });
            }
            else {
                const encodedPasswordLocal = data.encodedMsaPassword;
                if (encodedPasswordLocal) {
                    passwordBuffer = Crypto.CryptographicBuffer.decodeFromBase64String(encodedPasswordLocal);
                }
                const daTokenLocal = data.daToken;
                if (daTokenLocal) {
                    daTokenBuffer = Crypto.CryptographicBuffer.convertStringToBinary(daTokenLocal, Crypto.BinaryStringEncoding.utf8);
                }
                const sessionKeyLocal = data.sessionKey;
                if (sessionKeyLocal) {
                    sessionKeyBuffer = Crypto.CryptographicBuffer.convertStringToBinary(sessionKeyLocal, Crypto.BinaryStringEncoding.utf8);
                }
                let extension = getBrokeredExtension();
                return extension.createConnectedAccountAsync(data.userName, passwordBuffer, daTokenBuffer, data.daCreation, data.daExpiration, sessionKeyBuffer, data.flowToken, enableAutologon, Boolean(data.setDeviceOwner)).then((userId) => {
                    CloudExperienceHost.IUserManager.getInstance().setIUserFromId(userId.toString());
                    CloudExperienceHost.IUserManager.getInstance().setSignInIdentityProvider(CloudExperienceHostAPI.SignInIdentityProviders.msa);
                });
            }
        }
        MSA.createConnectedAccount = createConnectedAccount;
        function createStubAccount(username, isAdmin, localUserName) {
            if (typeof localUserName === 'undefined') {
                localUserName = '';
            }
            var extension = getBrokeredExtension();
            return extension.createStubAccountAsync(localUserName, username, isAdmin);
        }
        MSA.createStubAccount = createStubAccount;
        function initializeSmsAutoVerification() {
            startVerificationCodeWait();
            let extension = getMsaExtension();
            return extension.getPhoneNumbersFromDeviceAsync();
        }
        MSA.initializeSmsAutoVerification = initializeSmsAutoVerification;
        function getVerificationCode() {
            return _verificationCode;
        }
        MSA.getVerificationCode = getVerificationCode;
        function encryptUserData(plainText) {
            if (!plainText) {
                return WinJS.Promise.as("");
            }
            var provider = new Crypto.DataProtection.DataProtectionProvider("local=user");
            var buffer = Crypto.CryptographicBuffer.convertStringToBinary(plainText, Crypto.BinaryStringEncoding.utf8);
            return provider.protectAsync(buffer).then(function (protectedBuffer) {
                return Crypto.CryptographicBuffer.encodeToBase64String(protectedBuffer);
            });
        }
        MSA.encryptUserData = encryptUserData;
        function isNgcEnabled(username, puid) {
            let extension = getMsaExtensionForUser();
            let user = null;
            user = CloudExperienceHost.IUserManager.getInstance().getIUser();
            var usernameLocal = username || "";
            var puidLocal = puid || "";
            return extension.isNgcEnabledForUserAsync(user, usernameLocal, puidLocal);
        }
        MSA.isNgcEnabled = isNgcEnabled;
        function getContextParameterProperties() {
            let extension = getMsaExtensionForUser();
            let user = null;
            user = CloudExperienceHost.IUserManager.getInstance().getIUser();
            return extension.getContextParametersForUserAsync(user);
        }
        MSA.getContextParameterProperties = getContextParameterProperties;
        function getContextParameters(keysToInclude) {
            return getContextParameterProperties().then(function (params) {
                if (keysToInclude == null) {
                    return "";
                }
                var retParams = params;
                retParams = pluckKeys(params, keysToInclude);
                return objectToQueryString(retParams);
            });
        }
        MSA.getContextParameters = getContextParameters;
        function getContextParametersForLogin() {
            return getContextParameters(['mkt', 'platform', 'scid']);
        }
        MSA.getContextParametersForLogin = getContextParametersForLogin;
        function getContextParametersForKnownUserLogin() {
            const upn = CloudExperienceHost.Storage.VolatileSharableData.getItem("UserData", "upn");
            if (upn && (upn !== "")) {
                return getContextParametersForLogin().then(function (platformQueryString) {
                    return "username=" + upn +
                        "&" + platformQueryString;
                });
            }
            else {
                return getContextParametersForLogin();
            }
        }
        MSA.getContextParametersForKnownUserLogin = getContextParametersForKnownUserLogin;
        function getIdentityAppPropertiesHeader() {
            return getContextParameterProperties().then(function (params) {
                return params['username'] ? objectToQueryString({ 'loginhint': params['username'] }) : null;
            });
        }
        MSA.getIdentityAppPropertiesHeader = getIdentityAppPropertiesHeader;
        function getContextParametersForLoginWithScenarioContext() {
            return getContextParameters(['mkt', 'platform', 'scid', 'username']);
        }
        MSA.getContextParametersForLoginWithScenarioContext = getContextParametersForLoginWithScenarioContext;
        function getContextParametersForAccount() {
            return getContextParameters(['mkt', 'uiflavor', 'platform', 'hasngc']);
        }
        MSA.getContextParametersForAccount = getContextParametersForAccount;
        function getContextParametersForSSPR() {
            return getContextParameters(['mkt', 'uiflavor', 'platform', 'hasngc', 'mn']);
        }
        MSA.getContextParametersForSSPR = getContextParametersForSSPR;
        function getContextParametersForXbox() {
            var langCode = "en-US";
            var regionCode = "US";
            var inOobe = false;
            var useLightTheme = false;
            try {
                langCode = Windows.Xbox.System.Internal.Console.ConsoleProperties.currentNLSLanguage;
                regionCode = new Windows.Globalization.GeographicRegion().codeTwoLetter;
                var msaLocaleOverrides = Windows.Xbox.System.Internal.LiveSettings.LiveSettingGenerics.getString("MsaLocaleOverrides", "");
                if (msaLocaleOverrides) {
                    msaLocaleOverrides = JSON.parse(msaLocaleOverrides);
                    if (msaLocaleOverrides[langCode]) {
                        langCode = msaLocaleOverrides[langCode];
                    }
                }
            }
            catch (e) {
            }
            try {
                inOobe = !Windows.Xbox.System.Internal.XConfig.XConfigProperties.getIsOobeCompleted();
            }
            catch (e) {
            }
            try {
                var theme = Windows.Xbox.System.Internal.Personalization.SystemPersonalization.defaultSystemTheme;
                useLightTheme = (theme == Windows.Xbox.System.Internal.Personalization.SystemTheme.light);
            }
            catch (e) {
            }
            return getContextParameters(['platform']).then(function (platformQueryString) {
                return "mkt=" + langCode +
                    "&country=" + regionCode +
                    "&uitheme=" + (useLightTheme ? "xbox_2" : "xbox_1") +
                    (inOobe ? "&oobe=1" : "") +
                    "&" + platformQueryString;
            });
        }
        MSA.getContextParametersForXbox = getContextParametersForXbox;
        function getContextParametersForXboxConnectWithEmail() {
            let extension = getMsaExtensionForUser();
            let user = null;
            user = CloudExperienceHost.IUserManager.getInstance().getIUser();
            return extension.getUserEmailForUserAsync(user).then(function (emailAddress) {
                return getContextParametersForXbox().then(function (platformQueryString) {
                    return "username=" + emailAddress +
                        "&" + platformQueryString;
                });
            });
        }
        MSA.getContextParametersForXboxConnectWithEmail = getContextParametersForXboxConnectWithEmail;
        function saveAuthState(daToken, creation, expiry, sessionKey) {
            let extension = getBrokeredExtensionForUser();
            let user = null;
            user = CloudExperienceHost.IUserManager.getInstance().getIUser();
            let daTokenBuffer = null;
            if (daToken) {
                daTokenBuffer = Crypto.CryptographicBuffer.convertStringToBinary(daToken, Crypto.BinaryStringEncoding.utf8);
            }
            let sessionKeyBuffer = null;
            if (sessionKey) {
                sessionKeyBuffer = Crypto.CryptographicBuffer.decodeFromBase64String(sessionKey);
            }
            return extension.saveAuthStateForUserAsync(user, daTokenBuffer, creation, expiry, sessionKeyBuffer);
        }
        MSA.saveAuthState = saveAuthState;
        function associateAccount(data, daToken, creation, expiry, flowToken, sessionKey) {
            let userName = null;
            if (typeof (data) == "string") {
                userName = data;
            }
            else {
                userName = data.userName;
                daToken = data.daToken;
                creation = data.daCreation;
                expiry = data.daExpiration;
                flowToken = data.flowToken;
                sessionKey = data.sessionKey;
            }
            var extension = getMsaExtensionForUser();
            let user = null;
            user = CloudExperienceHost.IUserManager.getInstance().getIUser();
            if (typeof sessionKey === "undefined") {
                sessionKey = null;
            }
            let daTokenBuffer = null;
            if (daToken) {
                daTokenBuffer = Crypto.CryptographicBuffer.convertStringToBinary(daToken, Crypto.BinaryStringEncoding.utf8);
            }
            let sessionKeyBuffer = null;
            if (sessionKey) {
                sessionKeyBuffer = Crypto.CryptographicBuffer.convertStringToBinary(sessionKey, Crypto.BinaryStringEncoding.utf8);
            }
            return extension.associateAccountForUserAsync(user, userName, daTokenBuffer, creation, expiry, sessionKeyBuffer, flowToken);
        }
        MSA.associateAccount = associateAccount;
        function connectAccount(data, userName, encodedMsaPassword, daToken, daCreation, daExpiration, flowToken, sessionKey) {
            let encodedLocalPassword = null;
            let enableAutologon = false;
            if (typeof (data) == "string" || (!data && typeof (userName) == "string")) {
                encodedLocalPassword = data;
                let platform = CloudExperienceHost.Environment.getPlatform();
                enableAutologon = (platform == CloudExperienceHost.TargetPlatform.WINDOWS8828080);
            }
            else {
                encodedLocalPassword = data.encodedLocalPassword;
                userName = data.userName;
                encodedMsaPassword = data.encodedMsaPassword;
                daToken = data.daToken;
                daCreation = data.daCreation;
                daExpiration = data.daExpiration;
                flowToken = data.flowToken;
                sessionKey = data.sessionKey;
                enableAutologon = Boolean(data.enableAutologon);
            }
            let localPasswordBuffer = null;
            if (encodedLocalPassword) {
                localPasswordBuffer = Crypto.CryptographicBuffer.decodeFromBase64String(encodedLocalPassword);
            }
            let msaPasswordBuffer = null;
            if (encodedMsaPassword) {
                msaPasswordBuffer = Crypto.CryptographicBuffer.decodeFromBase64String(encodedMsaPassword);
            }
            let extension = getMsaExtensionForUser();
            let user = null;
            user = CloudExperienceHost.IUserManager.getInstance().getIUser();
            let daTokenBuffer = null;
            if (daToken) {
                daTokenBuffer = Crypto.CryptographicBuffer.convertStringToBinary(daToken, Crypto.BinaryStringEncoding.utf8);
            }
            let sessionKeyBuffer = null;
            if (sessionKey) {
                sessionKeyBuffer = Crypto.CryptographicBuffer.convertStringToBinary(sessionKey, Crypto.BinaryStringEncoding.utf8);
            }
            return extension.connectAccountForUserAsync(user, localPasswordBuffer, userName, msaPasswordBuffer, daTokenBuffer, daCreation, daExpiration, flowToken, sessionKeyBuffer, enableAutologon);
        }
        MSA.connectAccount = connectAccount;
        function setUpUserTransition(user, puid, encodedPassword, daToken, daCreation, daExpiry, flowToken, sessionKey, sessionKeyType) {
            user = user || "";
            puid = puid || "";
            daCreation = daCreation || "";
            daExpiry = daExpiry || "";
            flowToken = flowToken || "";
            sessionKeyType = sessionKeyType || "";
            let contextData = CloudExperienceHost.getCurrentNode().customProperty || "";
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("setUpUserTransition", JSON.stringify({
                contextData: contextData
            }));
            let daTokenBuffer = null;
            if (daToken) {
                daTokenBuffer = Crypto.CryptographicBuffer.convertStringToBinary(daToken, Crypto.BinaryStringEncoding.utf8);
            }
            let sessionKeyBuffer = null;
            if (sessionKey) {
                sessionKeyBuffer = Crypto.CryptographicBuffer.convertStringToBinary(sessionKey, Crypto.BinaryStringEncoding.utf8);
            }
            let encodedPasswordBuffer = null;
            if (encodedPassword) {
                encodedPasswordBuffer = Crypto.CryptographicBuffer.decodeFromBase64String(encodedPassword);
            }
            var extension = getMsaExtension();
            return extension.setUpCflUserTransitionDataAsync(user, puid, encodedPasswordBuffer, daTokenBuffer, daCreation, daExpiry, flowToken, sessionKeyBuffer, sessionKeyType, contextData, null).then((userId) => {
                CloudExperienceHost.IUserManager.getInstance().setIUserFromId(userId.toString());
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("UserId", userId.toString());
            });
        }
        MSA.setUpUserTransition = setUpUserTransition;
        function getDevicePostData() {
            var extension = getMsaExtensionForUser();
            let user = null;
            user = CloudExperienceHost.IUserManager.getInstance().getIUser();
            return extension.getDevicePostDataForUserAsync(user);
        }
        MSA.getDevicePostData = getDevicePostData;
        function getAuthTokenPostData() {
            let extension = getMsaExtensionForUser();
            let user = null;
            user = CloudExperienceHost.IUserManager.getInstance().getIUser();
            return extension.getSignedAuthTokensForUserAsync(user).then(function (fields) {
                return objectToQueryString(fields);
            });
        }
        MSA.getAuthTokenPostData = getAuthTokenPostData;
        function objectToQueryString(obj) {
            var components = [];
            Object.keys(obj).forEach(function (key) {
                components.push(escapeUrlParam(key) + '=' + escapeUrlParam(obj[key]));
            });
            return components.join('&');
        }
        function pluckKeys(obj, keysToPluck) {
            var result = {};
            Object.keys(obj).forEach(function (key) {
                if (keysToPluck.indexOf(key) !== -1) {
                    result[key] = obj[key];
                }
            });
            return result;
        }
        function setUserInfo(userInfo) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                var provider = new Crypto.DataProtection.DataProtectionProvider("local=user");
                var buffer = Crypto.CryptographicBuffer.convertStringToBinary(JSON.stringify(userInfo), Crypto.BinaryStringEncoding.utf8);
                provider.protectAsync(buffer).then(function (bufferProtected) {
                    _userInfo = Crypto.CryptographicBuffer.encodeToBase64String(bufferProtected);
                    completeDispatch();
                }.bind(this), errorDispatch);
            }.bind(this));
        }
        MSA.setUserInfo = setUserInfo;
        function getUserInfo() {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                if (_userInfo) {
                    var provider = new Crypto.DataProtection.DataProtectionProvider("local=user");
                    var buffer = Crypto.CryptographicBuffer.decodeFromBase64String(_userInfo);
                    provider.unprotectAsync(buffer).then(function (bufferUnprotected) {
                        var userInfo = JSON.parse(Crypto.CryptographicBuffer.convertBinaryToString(Crypto.BinaryStringEncoding.utf8, bufferUnprotected));
                        completeDispatch(userInfo);
                    }.bind(this), errorDispatch);
                }
                else {
                    completeDispatch(null);
                }
            }.bind(this));
        }
        MSA.getUserInfo = getUserInfo;
        function showKeyboardForXbox(show) {
            var virtualKeyboard = Windows.UI.ViewManagement.InputPane.getForCurrentView();
            if ((typeof show === 'undefined') || show) {
                virtualKeyboard.tryShow();
            }
            else {
                virtualKeyboard.tryHide();
            }
        }
        MSA.showKeyboardForXbox = showKeyboardForXbox;
        function getAadSscrParameters() {
            var extension = getMsaExtension();
            return extension.getAadSscrParametersAsync().then(function (params) {
                return objectToQueryString(params);
            });
        }
        MSA.getAadSscrParameters = getAadSscrParameters;
        function setUpAadUserTransition(userName, refreshToken, scenarioData) {
            var scenarioDataLocal = scenarioData || "";
            var extension = getMsaExtension();
            let refreshTokenBuffer = null;
            if (refreshToken) {
                refreshTokenBuffer = Crypto.CryptographicBuffer.convertStringToBinary(refreshToken, Crypto.BinaryStringEncoding.utf8);
            }
            return extension.setUpAadCflUserTransitionDataAsync(userName, refreshTokenBuffer, scenarioDataLocal);
        }
        MSA.setUpAadUserTransition = setUpAadUserTransition;
        function setUpAadUserPinResetTransition(userName, refreshToken, scenarioData) {
            let NgcCxhScenarioType = {
                NgcUnknown: 0,
                NgcOnly: 1,
                NgcAndHello: 2,
                NgcResetOnly: 3,
                NgcFixMeOnly: 4,
                Dsreg_Sspr: 5,
                NgcDestructiveResetOnly: 6,
                NgcNonDestructiveResetOnly: 7,
                NgcPinResetAuth: 8,
                AadWebAuth: 9,
                Dsreg_Sspr_v2: 10,
                NgcPinReset_v2: 11
            };
            if (CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("AADPinResetV2")) {
                var scenarioDataLocal = scenarioData || "";
                var extension = getMsaExtension();
                CloudExperienceHost.Storage.VolatileSharableData.addItem("scenarioData", "username", userName);
                CloudExperienceHost.Storage.VolatileSharableData.addItem("scenarioData", "drsRefreshToken", refreshToken);
                let refreshTokenBuffer = null;
                if (refreshToken) {
                    refreshTokenBuffer = Crypto.CryptographicBuffer.convertStringToBinary(refreshToken, Crypto.BinaryStringEncoding.utf8);
                }
                return new WinJS.Promise((completeDispatch, errorDispatch /*, progressDispatch */) => {
                    return extension.setUpAadCflUserPinResetTransitionDataAsync(userName, refreshTokenBuffer, scenarioDataLocal).then((pinResetScenario) => {
                        let scenarioType = pinResetScenario.hasKey("scenarioType") ? parseInt(pinResetScenario.lookup("scenarioType")) : 0;
                        if (scenarioType === NgcCxhScenarioType.NgcResetOnly || scenarioType === NgcCxhScenarioType.NgcNonDestructiveResetOnly) {
                            let recoveryServiceClientId = pinResetScenario.hasKey("recoveryServiceClientId") ? pinResetScenario.lookup("recoveryServiceClientId") : "";
                            let pinResetServiceResource = pinResetScenario.hasKey("pinResetServiceResource") ? pinResetScenario.lookup("pinResetServiceResource") : "";
                            let pinResetServiceRedirectUri = pinResetScenario.hasKey("pinResetServiceRedirectUri") ? pinResetScenario.lookup("pinResetServiceRedirectUri") : "";
                            if (recoveryServiceClientId !== "" && pinResetServiceResource !== "" && pinResetServiceRedirectUri !== "") {
                                CloudExperienceHost.Storage.PrivateData.addItem("recoveryServiceClientId", recoveryServiceClientId);
                                CloudExperienceHost.Storage.PrivateData.addItem("pinResetServiceResource", pinResetServiceResource);
                                CloudExperienceHost.Storage.PrivateData.addItem("pinResetServiceRedirectUri", pinResetServiceRedirectUri);
                                completeDispatch(scenarioType);
                            }
                            else if (scenarioType === NgcCxhScenarioType.NgcResetOnly) {
                                scenarioType = NgcCxhScenarioType.NgcDestructiveResetOnly;
                                completeDispatch(scenarioType);
                            }
                            else {
                                errorDispatch("SetUpAadUserPinResetTransition.MissingNonDestructiveResetScenarioParams");
                            }
                        }
                        else if (scenarioType === NgcCxhScenarioType.NgcDestructiveResetOnly) {
                            completeDispatch(scenarioType);
                        }
                        else {
                            errorDispatch("SetUpAadUserPinResetTransition.InvalidScenarioType: " + scenarioType.toString());
                        }
                    }, (e) => {
                        errorDispatch("SetUpAadUserPinResetTransition.FailedToGetNgcScenarioType");
                    });
                });
            }
            else {
                return new WinJS.Promise((completeDispatch /*, errorDispatch, progressDispatch */) => {
                    setUpAadUserTransition(userName, refreshToken, scenarioData).then(() => {
                        completeDispatch(NgcCxhScenarioType.NgcUnknown); //CXH_SCENARIO_TYPE::NgcUnknown
                    });
                });
            }
        }
        MSA.setUpAadUserPinResetTransition = setUpAadUserPinResetTransition;
        function getAccountInformation(userName, accountId) {
            let extension = getMsaExtensionForUser();
            let user = CloudExperienceHost.IUserManager.getInstance().getIUser();
            let userNameLocal = userName || "";
            let accountIdLocal = accountId || "";
            return extension.getAccountInformationForUserAsync(user, userNameLocal, accountIdLocal);
        }
        MSA.getAccountInformation = getAccountInformation;
        function startVerificationCodeWait() {
            cancelVerificationCodeWait();
            _verificationCode = null;
            _persistedMsaExtension = getMsaExtension();
            const codeError = "-1";
            _persistedMsaExtension.getVerificationCodeAsync().then((verificationCode) => {
                cancelVerificationCodeWait();
                if (verificationCode) {
                    _verificationCode = verificationCode;
                }
                else {
                    _verificationCode = codeError;
                }
            }, (e) => {
                cancelVerificationCodeWait();
                _verificationCode = codeError;
            });
        }
        function cancelVerificationCodeWait() {
            if (_persistedMsaExtension) {
                _persistedMsaExtension.cancelVerificationCodeWait();
                _persistedMsaExtension = null; // Need to make sure this gets cleaned up.
            }
        }
        function escapeUrlParam(value) {
            return encodeURIComponent(value).replace(/'/g, "%27");
        }
        function getMsaExtension() {
            return new MicrosoftAccount.Extension.ExtensionWorker();
        }
        function getMsaExtensionForUser() {
            return new MicrosoftAccount.Extension.ExtensionWorkerForUser();
        }
        function getBrokeredExtension() {
            return new MicrosoftAccount.UserOperations.Extension();
        }
        function getBrokeredExtensionForUser() {
            return new MicrosoftAccount.UserOperations.ExtensionForUser();
        }
        var ShouldSkipNGCEnroll;
        (function (ShouldSkipNGCEnroll) {
            function getShouldSkipAsync() {
                let extension = getMsaExtensionForUser();
                let user = null;
                user = CloudExperienceHost.IUserManager.getInstance().getIUser();
                return extension.isNgcCreateContainerDisabledForUserAsync(user);
            }
            ShouldSkipNGCEnroll.getShouldSkipAsync = getShouldSkipAsync;
        })(ShouldSkipNGCEnroll = MSA.ShouldSkipNGCEnroll || (MSA.ShouldSkipNGCEnroll = {}));
        var ShouldSkipAadNgcProvisioning;
        (function (ShouldSkipAadNgcProvisioning) {
            function getShouldSkipAsync() {
                let extension = getMsaExtensionForUser();
                let user = null;
                user = CloudExperienceHost.IUserManager.getInstance().getIUser();
                return extension.shouldSkipAadNgcProvisioningForUserAsync(user);
            }
            ShouldSkipAadNgcProvisioning.getShouldSkipAsync = getShouldSkipAsync;
        })(ShouldSkipAadNgcProvisioning = MSA.ShouldSkipAadNgcProvisioning || (MSA.ShouldSkipAadNgcProvisioning = {}));
    })(MSA = CloudExperienceHost.MSA || (CloudExperienceHost.MSA = {}));
})(CloudExperienceHost || (CloudExperienceHost = {}));

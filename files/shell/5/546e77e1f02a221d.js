"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    (function (CloudDomain) {
        function _getCloudDomainWorker() {
            if (!CloudDomain.hasOwnProperty("cloudDomainJoinWorker")) {
                CloudDomain.cloudDomainJoinWorker = new CloudDomainJoin.DataModel.CloudDomainJoinWorker();
            }
            return CloudDomain.cloudDomainJoinWorker;
        }

        var commonFeatures = [];

        function getCommonFeatures(allServerFeatures) {
            var allClientFeatures = [
                "JoinResultObject",
                "CentralizedGetPolicy", // Note: this really means that this version of CXH supports CloudExperienceHost.Policy.getPolicy*
                "CheckOSEditionUpgradeFeature",
                "MmpcRedirectFeature",
                "NativeGetPolicy",
            ];

            commonFeatures = allClientFeatures.filter(feature => allServerFeatures.includes(feature));
            return commonFeatures;
        }
        CloudDomain.getCommonFeatures = getCommonFeatures;

        function returnResultByValue(result) {
            var resultValueCopy = {};
            for (var propertyName in result) {
                resultValueCopy[propertyName] = result[propertyName];
            }

            return resultValueCopy;
        }

        function isErrorClassNotReg(error) {
            if (error.hasOwnProperty("number") && ((error.number >>> 0) === 0x80040154)) {
                return true;
            }
            return false;
        }

        function getPolicyString(policyName) {
            try {
                return EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getStringPolicyAsync(policyName);
            } catch (e) {
                if (isErrorClassNotReg(e)) {
                    return "";
                }
                
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("CDJUIGetPolicyStringFailure", JSON.stringify({objectType: e && e.toString(), status: e.status && e.status.toString()}));
                throw e;
            }
        }
        CloudDomain.getPolicyString = getPolicyString;

        function getPolicyBool(autoPilotOobeSetting) {
            try {
                return EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getOobeSettingsOverrideAsync(autoPilotOobeSetting);
            } catch (e) {
                if (isErrorClassNotReg(e)) {
                    return false;
                }

                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("CDJUIGetPolicyBoolFailure", JSON.stringify({objectType: e && e.toString(), status: e.status && e.status.toString()}));
                throw e;
            }
        }
        CloudDomain.getPolicyBool = getPolicyBool;

        function isAlreadyAzureADJoined() {
            var cloudDomainJoinWorker = _getCloudDomainWorker();
            return cloudDomainJoinWorker.isAlreadyAzureADJoinedAsync();
        }
        CloudDomain.isAlreadyAzureADJoined = isAlreadyAzureADJoined;

        function configureCredentialGuarantee(credentialPromptTitle, credentialPromptCaption) {
            var cloudDomainJoinWorker = _getCloudDomainWorker();
            return cloudDomainJoinWorker.configureCredentialGuarantee(credentialPromptTitle, credentialPromptCaption);
        }
        CloudDomain.configureCredentialGuarantee = configureCredentialGuarantee;

        function decodeJsonWebTokenPart(jwtPart) {
            var base64String = jwtPart.replace(/-/g, "+").replace(/_/g, "/");
            var utf8String = window.atob(base64String);
            var originalString = decodeURIComponent(escape(utf8String));
            return originalString;
        }

        function crackIdToken(idToken) {
            var parts = idToken.split(".");
            if (parts.length == 3) {
                var encodedPayload = parts[1];
                var jsonObjectValue = decodeJsonWebTokenPart(encodedPayload);
                return JSON.parse(jsonObjectValue);
            } else {
                throw new CloudExperienceHost.InvalidArgumentError();
            }
        }

        function getMmpcUrlsFromTokenAsync(idToken){
            let crackedIdToken = crackIdToken(idToken);
            let enterpriseManagementWorker = new EnterpriseDeviceManagement.Enrollment.ReflectedEnroller();
            return enterpriseManagementWorker.mmpcGetManagementUrlsAsync(crackedIdToken["upn"], getClientRequestId()).then(function(result) {
                return returnResultByValue(result);
            });
        }
        CloudDomain.getMmpcUrlsFromTokenAsync = getMmpcUrlsFromTokenAsync;

        function inPlacePromoteIdTokenProperties(propertySet) {
            var idTokenProperties = {
                mandatoryTokenProperties: {
                    upn: {
                        internalName: "tokenUpn",
                        tokenName: "upn",
                    },
                    sid: {
                        internalName: "tokenSid",
                        tokenName: "sid",
                    },
                    tid: {
                        internalName: "tokenTenantId",
                        tokenName: "tid",
                    },
                    displayName: {
                        internalName: "tokenTenantDisplayName",
                        tokenName: "tenant_display_name",
                    },
                },
                optionalTokenProperties: {
                    mdmEnrollmentUrl: {
                        internalName: "tokenMdmEnrollmentUrl",
                        tokenName: "mdm_enrollment_url",
                    },
                    mdmTermsOfUse: {
                        internalName: "tokenMdmTermsOfUseUrl",
                        tokenName: "mdm_terms_of_use_url",
                    },
                    mdmComplianceUrl: {
                        internalName: "tokenMdmComplianceUrl",
                        tokenName: "mdm_compliance_url",
                    },
                    settingSyncUrl: {
                        internalName: "tokenUserSettingSyncUrl",
                        tokenName: "user_setting_sync_url",
                    },
                },
            };

            var crackedIdToken = crackIdToken(propertySet["idToken"]);

            var mandatoryProperties = idTokenProperties.mandatoryTokenProperties;
            for (var property in mandatoryProperties) {
                propertySet[mandatoryProperties[property].internalName] = crackedIdToken[mandatoryProperties[property].tokenName];
            }

            var optionalProperties = idTokenProperties.optionalTokenProperties;
            for (var property in optionalProperties) {
                if (crackedIdToken.hasOwnProperty(optionalProperties[property].tokenName)) {
                    propertySet[optionalProperties[property].internalName] = crackedIdToken[optionalProperties[property].tokenName];
                }
            }
        }

        function inPlaceOverwriteMmpcUrlsFromTokenAsync(propertySet) {
            if (commonFeatures.includes("MmpcRedirectFeature") &&
                propertySet.hasOwnProperty("tokenMdmEnrollmentUrl") &&
                (propertySet["tokenMdmEnrollmentUrl"] != "")) {
                return getMmpcUrlsFromTokenAsync(propertySet["idToken"]).then(function (result) {
                    let isLockedDown = result.isMmpcLockedDown;
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("CDJIsMmpcLockedDown", isLockedDown);
                    if (isLockedDown) {
                        propertySet["tokenMdmEnrollmentUrl"] = result.getManagementUrlsEnrollmentUrl;
                        propertySet["tokenMdmTermsOfUseUrl"] = result.getManagementUrlsTermsOfUseUrl;
                    }
                    return propertySet;
                });
            } else {
                return WinJS.Promise.as(propertySet);
            }

        }

        function returnJoinResultByValue(joinResult) {
            var joinResultValueCopy = {};
            for (var propertyName in joinResult) {
                joinResultValueCopy[propertyName] = joinResult[propertyName];
            }

            return joinResultValueCopy;
        }

        function completeAzureADJoin(joinResult) {
            var cloudDomainJoinWorker = _getCloudDomainWorker();
            CloudExperienceHost.IUserManager.getInstance().setIUserFromId(cloudDomainJoinWorker.joiningUserId.toString());
            CloudExperienceHost.IUserManager.getInstance().setSignInIdentityProvider(CloudExperienceHostAPI.SignInIdentityProviders.aad);

            if (joinResult.resultType === 0) {
                CloudExperienceHost.Storage.SharableData.removeValue("resourceAccountDisplayName");
            }

            if (commonFeatures.includes("JoinResultObject")) {
                return returnJoinResultByValue(joinResult);
            } else {
                if (joinResult.resultType == 3) {                   // ResultType::Failed
                    throw { HResult: joinResult.failureResult };    // Simulate old behavior of failure HRESULT appearing via e.HResult
                } else {
                    return joinResult.resultType;
                }
            }
        }

        function doAzureADJoin() {
            var cloudDomainJoinWorker = _getCloudDomainWorker();

            var credPromptTitle = WinJS.Resources.getString('/cloudDomainJoin/CredPromptTitle').value;
            var credPromptCaption = WinJS.Resources.getString('/cloudDomainJoin/CredPromptCaption').value;
            cloudDomainJoinWorker.configureCredentialGuarantee(credPromptTitle, credPromptCaption);

            var propertySet = CloudExperienceHost.Storage.PrivateData.getValues();
            inPlacePromoteIdTokenProperties(propertySet);

            var resourceAccountDisplayName = CloudExperienceHost.Storage.SharableData.getValue("resourceAccountDisplayName");
            if (resourceAccountDisplayName) {
                propertySet["resourceAccountDisplayName"] = resourceAccountDisplayName;
            }

            propertySet["correlationId"] = "{" + getClientRequestId() + "}";

            return inPlaceOverwriteMmpcUrlsFromTokenAsync(propertySet).then(function(propertySet) {
                return cloudDomainJoinWorker.doAzureADJoinAsync(propertySet).then(function (joinResult) {
                    if ((CloudExperienceHost.getContext().host.toLowerCase() === "frx") && (joinResult.resultType === 0)) {
                        var tenantId = propertySet["idTokenTenantId"];
                        return CloudExperienceHostBroker.SyncEngine.OOBEOneDriveOptinCore.enableOneDriveBusinessPoliciesAsync(tenantId).then(function () {
                            return completeAzureADJoin(joinResult);
                        }, function (e) {
                            CloudExperienceHost.Telemetry.logEvent("CDJUIEnableOneDriveBusinessPoliciesAsyncFailure",
                                JSON.stringify({objectType: e && e.toString(), status: e.status && e.status.toString()}));
                            return completeAzureADJoin(joinResult);
                        });
                    }
                    return completeAzureADJoin(joinResult);
                });
            });
        }
        CloudDomain.doAzureADJoin = doAzureADJoin;

        function prepareOSLicenseUpgrade() {
            var cloudDomainJoinWorker = _getCloudDomainWorker();

            var propertySet = CloudExperienceHost.Storage.PrivateData.getValues();
            inPlacePromoteIdTokenProperties(propertySet);
            return cloudDomainJoinWorker.prepareOSLicenseUpgradeAsync(propertySet);
        }
        CloudDomain.prepareOSLicenseUpgrade = prepareOSLicenseUpgrade;

        function doConnectAADAccount(localAccountPassword) {
            var cloudDomainJoinWorker = _getCloudDomainWorker();

            var propertySet = CloudExperienceHost.Storage.PrivateData.getValues();
            inPlacePromoteIdTokenProperties(propertySet);

            if ((localAccountPassword == null) || (localAccountPassword === "")) {
                return cloudDomainJoinWorker.doConnectAADAccountAsync(propertySet).then(function (connectAADResult) {
                    return returnResultByValue(connectAADResult);
                });
            }
            else
            {
                var dataProtectionProvider = new Windows.Security.Cryptography.DataProtection.DataProtectionProvider("local=user");
                var utf8EncodedPassword = Windows.Security.Cryptography.CryptographicBuffer.convertStringToBinary(localAccountPassword, Windows.Security.Cryptography.BinaryStringEncoding.utf8);

                return dataProtectionProvider.protectAsync(utf8EncodedPassword).then(function (protectedLocalAccountPassword) {
                    var encodedLocalAccountPassword = Windows.Security.Cryptography.CryptographicBuffer.encodeToBase64String(protectedLocalAccountPassword);
                    propertySet["encodedLocalAccountPassword"] = encodedLocalAccountPassword;

                    return cloudDomainJoinWorker.doConnectAADAccountAsync(propertySet);

                }).then(function (connectAADResult) {
                    return returnResultByValue(connectAADResult);
                });
            }
        }
        CloudDomain.doConnectAADAccount = doConnectAADAccount;

        function isOSEditionUpgradeFeatureEnabled(feature) {
            var cloudDomainJoinWorker = _getCloudDomainWorker();
            return cloudDomainJoinWorker.isOSEditionUpgradeFeatureEnabledAsync(feature);
        }
        CloudDomain.isOSEditionUpgradeFeatureEnabled = isOSEditionUpgradeFeatureEnabled;

        function getAuthorizationEndpoint(discoveryUrl) {
            var correlationId = getClientRequestId();
            return WinJS.xhr({
                    url: discoveryUrl,
                    headers: {
                        "client-request-id": correlationId,
                        "cxh-correlationId": correlationId
                    }
                }).then(function (response) {
                    return JSON.parse(response.responseText)["authorization_endpoint"];
                }, function (e) {
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("CDJUIDiscoveryFailure", JSON.stringify({objectType: e && e.toString(), status: e.status && e.status.toString()}));
                    return Promise.reject(e);
                });
        }
        CloudDomain.getAuthorizationEndpoint = getAuthorizationEndpoint;

        function getRecoveryUpn() {
            var cloudDomainJoinWorker = _getCloudDomainWorker();
            return cloudDomainJoinWorker.getRecoveryUpnAsync();
        }
        CloudDomain.getRecoveryUpn = getRecoveryUpn;

        function doRecovery() {
            var cloudDomainJoinWorker = _getCloudDomainWorker();

            var propertySet = CloudExperienceHost.Storage.PrivateData.getValues();
            inPlacePromoteIdTokenProperties(propertySet);
            return cloudDomainJoinWorker.doRecoveryAsync(propertySet);
        }
        CloudDomain.doRecovery = doRecovery;

        function revertZtdPolicy() {
            var cloudDomainJoinWorker = _getCloudDomainWorker();
            return cloudDomainJoinWorker.revertZtdPolicyAsync();
        }
        CloudDomain.revertZtdPolicy = revertZtdPolicy;

        function isCancellationAllowed() {
            var allowed = true;
            if (CloudExperienceHost.getContext().host.toLowerCase() === "frx") {
                var allowedProviders = CloudExperienceHostAPI.SignInIdentities.allowedProviders;
                var signInProvidersflag = CloudExperienceHostAPI.SignInIdentityProviders;

                if (0 === (allowedProviders & signInProvidersflag.msa)) {
                    allowed = false;
                }
            }
            return allowed;
        }
        CloudDomain.isCancellationAllowed = isCancellationAllowed;

        function getClientRequestId() {
            return CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().getId();
        }
        CloudDomain.getClientRequestId = getClientRequestId;

        function getMsAadjRedirQueryTerms() {
            var msAadjRedirQueryTermsPropertyName = "msAadjRedirQueryTerms";

            var propertySet = CloudExperienceHost.Storage.PrivateData.getValues();

            var queryTerms = "";
            if (propertySet.hasOwnProperty(msAadjRedirQueryTermsPropertyName)) {
                queryTerms = propertySet[msAadjRedirQueryTermsPropertyName];

                CloudExperienceHost.Storage.PrivateData.addItem(msAadjRedirQueryTermsPropertyName, "");
            }

            return queryTerms;
        }
        CloudDomain.getMsAadjRedirQueryTerms = getMsAadjRedirQueryTerms;

    })(CloudExperienceHost.CloudDomain || (CloudExperienceHost.CloudDomain = {}));
    var CloudDomain = CloudExperienceHost.CloudDomain;
})(CloudExperienceHost || (CloudExperienceHost = {}));

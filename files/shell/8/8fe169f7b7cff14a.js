(function () {
    "use strict";

    var bridge = new CloudExperienceHost.Bridge();
    var resources;
    var navFlow;
    var rdamJson = null;
    var passwordErrorExists = false; // True iff the passwords don't match or are empty
    var blockNext = false; // If true, block the next button
	var isLiteWhitePersonality = false;

    WinJS.UI.Pages.define("/RetailDemo/retailDemoSecurityInclusive.html", {
        init: function (element, options) {
            require.config(new RequirePathConfig('/webapps/inclusiveOobe'));
            let pagePromise = bridge.invoke("CloudExperienceHost.StringResources.getRetailDemoStrings").done(function (result) {
                resources = JSON.parse(result);
            });
            let cssPromise = uiHelpers.LoadCssPromise(document.head, "..", bridge);
            let languagePromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getPreferredLang").then(function (preferredLang) {
                _rdxHtmlRoot.setAttribute("lang", preferredLang);
            }, function () { });
            let dirPromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getReadingDirection").then(function (dirVal) {
                _rdxHtmlRoot.setAttribute("dir", dirVal);
            }, function () { });
            let navFlowPromise = bridge.invoke("CloudExperienceHost.getContext").then(function (result) {
                navFlow = result.host;
            }, function () { });
            
			let promisesToJoin = { 
                pagePromise: pagePromise, 
                cssPromise: cssPromise, 
                languagePromise: languagePromise, 
                dirPromise: dirPromise, 
                navFlowPromise: navFlowPromise 
            };

            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RDX_OOBE_Accessibility_Improvements")) {
                var personalityPromise = bridge.invoke("CloudExperienceHost.getContext").then(function (result) {
                    isLiteWhitePersonality = (result.personality === CloudExperienceHost.TargetPersonality.LiteWhite);
                });
                promisesToJoin.personalityPromise = personalityPromise;
            }
            return WinJS.Promise.join(promisesToJoin);
        },

        ready: function (element, options) {
            let processingFlag = false;

            document.title = resources.rdxTitle;
            securityTitle.textContent = resources.securityTitle;
            securityText.textContent = resources.securityText;
            passwordManagmentLegend.textContent = resources.passwordManagmentLegend;
            timeoutLegend.textContent = resources.timeoutLegend;
            passwordLegend.textContent = resources.passwordLegend;
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RDX_OOBE_Password_Label_Accessibility")) {
                passwordInputCheck.setAttribute("aria-label", resources.confirmPassword);
                passwordInput.setAttribute("placeholder", resources.passwordSuggestion);
                passwordInputCheck.setAttribute("placeholder", resources.confirmPassword);
                passwordInputCheck.setAttribute("aria-roledescription", resources.editField);
            }

            passwordManagementToggle.disabled = true;

            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RDX_OOBE_Toggle_Control_Type_Accessibility")) {
                passwordManagementToggle.setAttribute("aria-label", resources.passwordManagmentLegend);
                passwordManagementToggle.setAttribute("role", "switch");
            }

            if (navFlow === "FRXINCLUSIVE") {
                nextButton.textContent = resources.nextButton;
            } else {
                nextButton.textContent = resources.finishButton;
            }

            passwordInputCheck.addEventListener("change", passwordCheck);
            passwordInput.addEventListener("change", passwordCheck);
            
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RDX_OOBE_Narrator_ScanMode_Activation_Accessibility")) {
                passwordManagementToggle.addEventListener("click", function (eventInfo) {
                    passwordManagementToggle.winControl.checked = !passwordManagementToggle.winControl.checked;
                    eventInfo.preventDefault();
                });

                passwordManagementToggle.addEventListener("pointerdown", onPointerDownHandler, true /*useCapture*/);
            }

             passwordManagementToggle.addEventListener("change", function (eventInfo) {
                eventInfo.preventDefault();
                if (passwordManagementToggle.winControl.checked) {
                    timeoutElements.style.display = "inline";
                    passwordElements.style.display = "none";
                    allowUserToContinue();
                    if (passwordError.firstChild) {
                        passwordError.removeChild(passwordError.firstChild);
                    }
                } else {
                    timeoutElements.style.display = "none";
                    passwordElements.style.display = "inline";
                    passwordCheck(); 
                }
            });

            for (let i = 0; i < 22; i++) {
                let option = document.createElement("option");
                option.value = i * 24;
                if (i == 0) {
                    option.text = resources.immediatelyText;
                } else if (i == 1) {
                    option.text = resources.dayText.replace("{0}", i);
                } else {
                    option.text = resources.daysText.replace("{0}", i);
                }

                timeoutSelect.appendChild(option);
            }

            timeoutSelect.selectedIndex = 3;

            let racValue;
            if (Windows.System.Profile.RetailInfo.properties.hasKey("RetailAccessCode")) {
                racValue = Windows.System.Profile.RetailInfo.properties.lookup("RetailAccessCode");
            }

            preventContinue();
            let racOption = {
                url: "https://retailstore.microsoft.com/RedecsService/Content/api/attributes/metadata?RAC=" + racValue,
                responseType: "json"
            };
            WinJS.Promise.timeout(30000, bridge.invoke("WinJS.xhr", racOption)).then(
                function (result) {
                    rdamJson = result.response;
                    passwordInput.value = rdamJson.RetailerAccessCodes[0].AdminPassword;
                    passwordInputCheck.value = rdamJson.RetailerAccessCodes[0].AdminPassword;
                    passwordManagementToggle.disabled = false
                    allowUserToContinue();
                },
                function (error) {
                    if ((error.message === "Canceled") || (error.status === 0)) {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "RdamRequestTimeout");
                    } else {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "InvalidRac", racValue);
                    }
                    passwordManagementToggle.disabled = false
                    allowUserToContinue();
                }
            );

            nextButton.addEventListener("click", function (eventInfo) {
                eventInfo.preventDefault();
                if (!processingFlag) {
                    if (!blockNext) {
                        processingFlag = true;
                        bridge.fireEvent(CloudExperienceHost.Events.showProgressWhenPageIsBusy);

                        if (passwordManagementToggle.winControl.checked) {
                            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "DisableAdminSelected", timeoutSelect[timeoutSelect.selectedIndex].value);
                            bridge.invoke("RetailDemo.Internal.RetailInfoSetter.setDWORDAsync", "DelayDisableAdminAccess", timeoutSelect[timeoutSelect.selectedIndex].value)
                            .done(() => {
                                retailDemoShared.SetupPageSuccessNavigation(rdamJson ? rdamJson.RetailerAccessCodes[0].AdminPassword : null, navFlow, bridge);
                            });
                        } else {
                            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CustomPasswordSelected");
                            bridge.invoke("RetailDemo.Internal.RetailInfoSetter.setDWORDAsync", "DelayDisableAdminAccess", 4294967295) // max dword
                            .done(() => {
                                retailDemoShared.SetupPageSuccessNavigation(passwordInput.value, navFlow, bridge);
                            });
                        }
                    } else if (passwordInput.value.length == 0) {
                        showPasswordError(resources.enterPassword);
                    } else if (passwordInputCheck.value.length == 0) {
                        showPasswordError(resources.retypePassword);
                    }
                }
            });

            if (!CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RDX_DisableAdminAccount")) {
                retailDemoShared.SetupPageSuccessNavigation(null, navFlow, bridge);
            } else {
                bridge.fireEvent(CloudExperienceHost.Events.visible, true);
            }

            function showPasswordError(message) {
                if (passwordError.firstChild) {
                    passwordError.removeChild(passwordError.firstChild);
                }
                passwordErrorExists = true;
                passwordError.classList.add("inputState_error");
                let text = document.createElement("p");
                text.textContent = message;
                text.setAttribute("aria-hidden", "true");
                let tooltip = document.createElement("div");

                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RDX_OOBE_Accessibility_Improvements")) {
                    if (isLiteWhitePersonality) {
                            tooltip.className = "errorDialog-dialogRoot template-tooltip tooltipType_error_rdx";
                    } else {
                        tooltip.className = "errorDialog-dialogRoot template-tooltip tooltipType_error_rdx_blueStyle";  
                    }
                } else {
                    if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RDX_OOBE_Alert_Contrast_Mode_Accessibility")) {
                        tooltip.className = "errorDialog-dialogRoot template-tooltip tooltipType_error_rdx";
                    } else {
                        tooltip.className = "errorDialog-dialogRoot template-tooltip tooltipType_error";
                    }
                }
				
                tooltip.appendChild(text);

                passwordError.appendChild(tooltip);
                passwordError.setAttribute("aria-label", message);
                passwordError.style.display = 'inline';
            }

            function allowUserToContinue() {
                nextButton.classList.add("button_primary");
                blockNext = false;
            }

            function preventContinue() {
                nextButton.classList.remove("button_primary");
                blockNext = true;
            }

            function passwordCheck() {
                if (passwordErrorExists) {
                    passwordError.style.display = 'none';
                    passwordError.setAttribute("aria-label", null);
                    passwordError.classList.remove("inputState_error");
                    if (passwordError.firstChild) {
                        passwordError.removeChild(passwordError.firstChild);
                    }
                    passwordErrorExists = false;
                }

                if ((passwordInput.value.length == 0) || (passwordInputCheck.value.length == 0)) {
                    preventContinue();
                } else if (passwordInput.value != passwordInputCheck.value) {
                    preventContinue();
                    showPasswordError(resources.passwordError);
                } else {
                    if (blockNext) {
                        allowUserToContinue();
                    }
                }
            }

            function onPointerDownHandler(ev) {
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RDX_OOBE_Narrator_ScanMode_Activation_Accessibility")) {
                    ev.stopImmediatePropagation();
                }
            }
        }
    });
})();

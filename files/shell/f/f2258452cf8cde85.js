(function () {
    "use strict";
    var localAccountResources = {};
    var bridge = new CloudExperienceHost.Bridge();
    var validator = new uiHelpers.Validator();
    var errorClass = new uiHelpers.ErrorUI();
    var isSQSAAllowed = true;
    WinJS.UI.Pages.define("/views/localAccount.html", {
        init: function (element, options) {
            var languagePromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getPreferredLang").then(function (preferredLang) {
                _htmlRoot.setAttribute("lang", preferredLang);
            }, function () { });
            var dirPromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getReadingDirection").then(function (dirVal) {
                _htmlRoot.setAttribute("dir", dirVal);
            }, function () { });
            var stringPromise = bridge.invoke("CloudExperienceHost.LocalAccount.localizedStrings").then(function (result) {
                localAccountResources = JSON.parse(result);
            });
            var sqsaEnabledPromise = bridge.invoke("CloudExperienceHost.LocalAccount.isSQSAAllowed").then(function (isEnabled) {
                isSQSAAllowed = isEnabled;
            });
            var cssPromise = uiHelpers.LoadCssPromise(document.head, "..", bridge);
            return WinJS.Promise.join({ languagePromise: languagePromise, dirPromise: dirPromise, stringPromise: stringPromise, cssPromise: cssPromise, sqsaEnabledPromise: sqsaEnabledPromise });
        },
        ready: function (element, options) {
            userName.setAttribute('maxLength', '20');
            let setContentFor = [Title, LeadText1, LeadText, UserNameLegend, PasswordLegend, SQSALegend, NextButton, BackButton];
            for (let i = 0; i < setContentFor.length; i++) {
                setContentFor[i].innerHTML = localAccountResources[setContentFor[i].id];
            }
            let placeholderKey = [userName, password, passwordValidate, passwordHint, securityAnswer1, securityAnswer2, securityAnswer3];
            let placeholderValue = ['UserPlaceholder', 'PasswordPlaceholder', 'ReenterPlaceholder', 'HintPlaceholder',
                            'SecurityAnswerPlaceholder', 'SecurityAnswerPlaceholder', 'SecurityAnswerPlaceholder'];
            for (let i = 0; i < placeholderKey.length; i++) {
                placeholderKey[i].setAttribute('placeholder', localAccountResources[placeholderValue[i]]);
                placeholderKey[i].setAttribute('aria-label', localAccountResources[placeholderValue[i]]);
            }
            let securityQuestionDropdown = [securityQuestion1, securityQuestion2, securityQuestion3];
            let questionPlaceholderValue = ['SecurityQuestion1Placeholder', 'SecurityQuestion2Placeholder', 'SecurityQuestion3Placeholder'];
            const NUM_SECURITY_QUESTIONS = 6;
            for (let i = 0; i < securityQuestionDropdown.length; i++) {
                let currDropdown = securityQuestionDropdown[i];
                currDropdown.options[0] = new Option(localAccountResources[questionPlaceholderValue[i]], '', true, true);
                for (let j = 1; j <= NUM_SECURITY_QUESTIONS; j++) {
                    let question = localAccountResources['SecurityQuestion' + j];
                    currDropdown.options[j] = new Option(question, question);
                    currDropdown.options[j].title = question;
                }
            }
            SQSAFieldset.style.display = 'none';
            NextButton.addEventListener("click", function (event) {
                event.preventDefault();
                _onNext.apply(this);
            }.bind(this));
            let checkAmersandFor = [NextButton, BackButton];
            checkAmersandFor.forEach(function (eachElement) {
                let result = CloudExperienceHost.ResourceManager.GetContentAndAccesskey(localAccountResources[eachElement.id]);
                eachElement.textContent = result.content;
                eachElement.accessKey = result.accessKey;
            });
            bridge.invoke("CloudExperienceHost.Environment.hasInternetAccess").done(function (isConnectedToNetwork) {
                if (!isConnectedToNetwork) {
                    BackButton.style.display = "none";
                }
            });
            bridge.invoke("CloudExperienceHost.getContext").done(function (context) {
                if (context.host.toLowerCase() === "setaddlocalonly") {
                    BackButton.style.display = "none";
                }
            });
            BackButton.addEventListener("click", function () {
                bridge.fireEvent(CloudExperienceHost.Events.goBack);
            });
            userName.addEventListener("blur", function () {
                let errorCode = validator.validateUsername(userName);
                _checkErrorCodeAndShowError(this, errorCode);
            }.bind(this));
            userName.addEventListener("keyup", function () {
                let errorCode = validator.validateUsername(userName);
                _checkErrorCodeAndHideError(userName, errorCode, userName_errorDialog);
            });
            password.addEventListener("blur", function () {
                if ((passwordValidate.value.length >= 1) || (password.value.length === 0)) {
                    let errorCode = validator.preCheckPassword(password, passwordValidate);
                    _checkErrorCodeAndShowError(this, errorCode);
                }
                SQSAFieldset.style.display = (password.value.length === 0) ? 'none' : '';
            }.bind(this));
            password.addEventListener("keyup", function () {
                _hideErrorDialogsOnValidPassword();
                SQSAFieldset.style.display = (password.value.length === 0) ? 'none' : '';
            });
            passwordValidate.addEventListener("blur", function () {
                let errorCode = validator.preCheckPassword(password, passwordValidate);
                _checkErrorCodeAndShowError(this, errorCode);
            }.bind(this));
            passwordValidate.addEventListener("keyup", _hideErrorDialogsOnValidPassword);
            passwordHint.addEventListener("blur", function () {
                let errorCode = validator.validateHint(password, passwordHint);
                _checkErrorCodeAndShowError(this, errorCode);
            }.bind(this));
            passwordHint.addEventListener("keyup", function () {
                let errorCode = validator.validateHint(password, passwordHint);
                _checkErrorCodeAndHideError(passwordHint, errorCode, passwordHint_errorDialog);
            });
            let securityQuestionErrorDialog = [securityQuestion1_errorDialog, securityQuestion2_errorDialog, securityQuestion3_errorDialog];
            for (let i = 0; i < securityQuestionDropdown.length; i++) {
                let currSecurityQuestionDropdown = securityQuestionDropdown[i];
                let otherDropdowns = securityQuestionDropdown.slice();
                otherDropdowns.splice(i, 1);
                currSecurityQuestionDropdown.addEventListener('focus', function (otherDropdowns) {
                    for (let j = 0; j < this.options.length; j++) {
                        this.options[j].disabled = false;
                    }
                    otherDropdowns.filter(item => item.selectedIndex !== 0)
                        .forEach(item => this.options[item.selectedIndex].disabled = true);
                }.bind(currSecurityQuestionDropdown, otherDropdowns));
                currSecurityQuestionDropdown.addEventListener("blur", function (questionDropdown, questionNumber) {
                    let errorCode = validator.validateSecurityQuestionSelection(password, questionDropdown, questionNumber);
                    _checkErrorCodeAndShowError(this, errorCode);
                }.bind(this, currSecurityQuestionDropdown, i));
                currSecurityQuestionDropdown.addEventListener("change", function (securityErrorDialog, questionNumber) {
                    let errorCode = validator.validateSecurityQuestionSelection(password, this, questionNumber);
                    _checkErrorCodeAndHideError(this, errorCode, securityErrorDialog);
                }.bind(currSecurityQuestionDropdown, securityQuestionErrorDialog[i], i));
            }
            let securityAnswerInput = [securityAnswer1, securityAnswer2, securityAnswer3];
            let securityAnswerErrorDialog = [securityAnswer1_errorDialog, securityAnswer2_errorDialog, securityAnswer3_errorDialog];
            for (let i = 0; i < securityAnswerInput.length; i++) {
                let currSecurityAnswerInput = securityAnswerInput[i];
                currSecurityAnswerInput.addEventListener("blur", function (inputField, answerNumber) {
                    let errorCode = validator.validateSecurityAnswer(password, inputField, answerNumber);
                    _checkErrorCodeAndShowError(this, errorCode);
                }.bind(this, currSecurityAnswerInput, i));
                currSecurityAnswerInput.addEventListener("keyup", function (securityErrorDialog, answerNumber) {
                    let errorCode = validator.validateSecurityAnswer(password, this, answerNumber);
                    _checkErrorCodeAndHideError(this, errorCode, securityErrorDialog);
                }.bind(currSecurityAnswerInput, securityAnswerErrorDialog[i], i));
            }
            if (isSQSAAllowed) {
                passwordHint_input.style.display = 'none';
            } else {
                SQSA_input.style.display = 'none';
                SQSALegend.style.display = 'none';
            }
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "LocalAccountCreationStart",
                JSON.stringify({
                    "recoveryKind": isSQSAAllowed ? "Security Questions" : "Hint",
                    "enrollingFrom": "Settings"
                }));

            uiHelpers.RegisterEaseOfAccess(easeOfAccess, bridge);
            uiHelpers.RegisterInputSwitcher(inputSwitcher, bridge);

            bridge.fireEvent(CloudExperienceHost.Events.visible, true);

            function _onNext() {
                _setProgressState(true);
                let inputErrors = [];
                let validInput = false;
                let recoveryData = passwordHint.value;
                let recoveryKind = "hint";
                if (isSQSAAllowed) {
                    inputErrors = validator.validateAllList(userName, password, passwordValidate, [securityQuestion1, securityQuestion2, securityQuestion3],
                        [securityAnswer1, securityAnswer2, securityAnswer3]);
                    if (inputErrors.length === 0) {
                        validInput = true;
                        if (password.value.length > 0) { // no questions if there's no password
                            recoveryData = _serializeQuestions(); // unable to directly call serialize() on fieldset
                            recoveryKind = "Security Questions";
                        }
                    }
                } else {
                    var result = validator.validateAll(userName, password, passwordValidate, passwordHint);
                    if (result === ErrorCodes.SUCCESS) {
                        validInput = true;
                    } else {
                        inputErrors = [result];
                    }
                }
                if (validInput) {
                    bridge.invoke("CloudExperienceHost.LocalAccount.createLocalAccount", userName.value.trim(), password.value, recoveryData).done(function () {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "LocalAccountCreationSuccess",
                            JSON.stringify({
                                "passwordUsed": (password.value.length > 0) ? "Password" : "NoPassword",
                                "recoveryKind": recoveryKind,
                                "enrolledFrom": "Settings"
                            }));
                        bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.success);
                    }, function (e) {
                        _setProgressState(false);
                        this._showError(this._getErrorCode(e.number), true /* setFocus */);
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "LocalAccountCreationFailure", JSON.stringify({ errorNumber: e.number.toString(16), errorStack: e.asyncOpSource.stack }));
                    }.bind(this));
                }
                else {
                    for (let i = 0; i < inputErrors.length; i++) {
                        this._showError(inputErrors[i], (i === 0) /* setFocus */);
                    }
                    _setProgressState(false);
                }
            }

            function _setProgressState(waiting) {
                NextButton.disabled = waiting;
                uiHelpers.SetElementVisibility(progressRing, waiting);
                userName.disabled = waiting;
                password.disabled = waiting;
                passwordValidate.disabled = waiting;
                passwordHint.disabled = waiting;
                securityQuestion1.disabled = waiting;
                securityAnswer1.disabled = waiting;
                securityQuestion2.disabled = waiting;
                securityAnswer2.disabled = waiting;
                securityQuestion3.disabled = waiting;
                securityAnswer3.disabled = waiting;
            }

            function _serializeQuestions() {
                let questions = [];
                let securityQuestions = [securityQuestion1, securityQuestion2, securityQuestion3];
                let securityAnswers = [securityAnswer1, securityAnswer2, securityAnswer3];
                for (let i = 0; i < securityQuestions.length; i++) {
                    questions.push({ 'question': securityQuestions[i].value, 'answer': securityAnswers[i].value });
                }
                return JSON.stringify({ version: 1.0, questions: questions });
            }

            function _hideErrorDialogsOnValidPassword() {
                if (validator.preCheckPassword(password, passwordValidate) === ErrorCodes.SUCCESS) {
                    errorClass.HideError(passwordValidate, passwordValidate_errorDialog);
                }
                if (password.value.length === 0) {
                    let securityInputs = [securityQuestion1, securityQuestion2, securityQuestion3,
                        securityAnswer1, securityAnswer2, securityAnswer3];
                    securityInputs.forEach(input => {
                        errorClass.HideError(input, document.getElementById(input.id + '_errorDialog'));
                    });
                }
            }

            function _checkErrorCodeAndShowError(thisArg, validatorErrorCode) {
                if (validatorErrorCode !== ErrorCodes.SUCCESS) {
                    thisArg._showError(validatorErrorCode, false /* setFocus */);
                }
            }

            function _checkErrorCodeAndHideError(inputField, validatorErrorCode, errorDialog) {
                if (validatorErrorCode === ErrorCodes.SUCCESS) {
                    errorClass.HideError(inputField, errorDialog);
                }
            }
        },
        error: function (e) {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "LocalAccountPageError", JSON.stringify({ number: e && e.number, stack: e && e.asyncOpSource && e.asyncOpSource.stack }));
            bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.fail);
        },
        _getErrorCode: function (errorNumber) {
            let errorCode = uiHelpers.GetErrorCodeFromError(errorNumber);
            return errorCode;
        },
        _showError: function (errorCode, setFocus) {
            let resourceId = null;
            let inputField = null;
            switch (errorCode) {
                case ErrorCodes.PasswordPlaceholder:
                    resourceId = 'PasswordPlaceholder';
                    inputField = passwordValidate;
                    break;
                case ErrorCodes.ReenterPlaceholder:
                    resourceId = 'ReenterPlaceholder';
                    inputField = passwordValidate;
                    break;
                case ErrorCodes.HintPlaceholder:
                    resourceId = 'HintPlaceholder';
                    inputField = passwordHint;
                    break;
                case ErrorCodes.SecurityQuestion1_Error:
                    resourceId = 'SQSA_Error';
                    inputField = securityQuestion1;
                    break;
                case ErrorCodes.SecurityQuestion2_Error:
                    resourceId = 'SQSA_Error';
                    inputField = securityQuestion2;
                    break;
                case ErrorCodes.SecurityQuestion3_Error:
                    resourceId = 'SQSA_Error';
                    inputField = securityQuestion3;
                    break;
                case ErrorCodes.SecurityAnswer1_Error:
                    resourceId = 'SQSA_Error';
                    inputField = securityAnswer1;
                    break;
                case ErrorCodes.SecurityAnswer2_Error:
                    resourceId = 'SQSA_Error';
                    inputField = securityAnswer2;
                    break;
                case ErrorCodes.SecurityAnswer3_Error:
                    resourceId = 'SQSA_Error';
                    inputField = securityAnswer3;
                    break;
                case ErrorCodes.UserEmpty_Error_Title:
                    resourceId = 'UserEmpty_Error_Title';
                    inputField = userName;
                    break;
                case ErrorCodes.LocalUser_NoUsername_Error:
                    resourceId = 'LocalUser_NoUsername_Error';
                    inputField = userName;
                    break;
                case ErrorCodes.Username_Too_Long:
                    resourceId = 'Username_Too_Long';
                    inputField = userName;
                    break;
                case ErrorCodes.Username_Error:
                    resourceId = 'Username_Error';
                    inputField = userName;
                    break;
                case ErrorCodes.UsernameContainsAt_Error:
                    resourceId = 'UsernameContainsAt_Error';
                    inputField = userName;
                    break;
                case ErrorCodes.UserExists_Error:
                    resourceId = 'UserExists_Error';
                    inputField = userName;
                    break;
                case ErrorCodes.UserReserved_Error:
                    resourceId = 'UserReserved_Error';
                    inputField = userName;
                    break;
                case ErrorCodes.UserIsComputer_Error_Title:
                    resourceId = 'UserIsComputer_Error_Title';
                    inputField = userName;
                    break;
                case ErrorCodes.PasswordHint_Empty_Error:
                    resourceId = 'PasswordHint_Empty_Error';
                    inputField = passwordHint;
                    break;
                case ErrorCodes.PasswordHint_Invalid_Error:
                    resourceId = 'PasswordHint_Invalid_Error';
                    inputField = passwordHint;
                    break;
                case ErrorCodes.PasswordConfirm_Error:
                    resourceId = 'PasswordConfirm_Error';
                    inputField = passwordValidate;
                    break;
                case ErrorCodes.PasswordPolicy_Error:
                    resourceId = 'PasswordPolicy_Error';
                    inputField = passwordValidate;
                    break;
                case ErrorCodes.Error_Creating_Account_Warning:
                    resourceId = 'Error_Creating_Account_Warning';
                    inputField = passwordHint;
                    if (isSQSAAllowed) {
                        inputField = securityAnswer3;
                    }
                    break;
                default:
                    break;
            }
            if (resourceId && inputField) {
                errorClass.ShowError(inputField, document.getElementById(inputField.id + '_errorDialog'), localAccountResources[resourceId]);
                if (setFocus) {
                    inputField.focus();
                }
            }
        },
    });
})();

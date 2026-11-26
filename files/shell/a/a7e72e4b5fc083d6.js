(function () {
    "use strict";
    let localAccountResources = {};
    let bridge = new CloudExperienceHost.Bridge();
    let validator = new uiHelpers.Validator();
    let errorClass = new uiHelpers.ErrorUI();
    WinJS.UI.Pages.define("/views/sqsaLocalAccount.html", {
        init: function (element, options) {
            let languagePromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getPreferredLang").then(function (preferredLang) {
                _htmlRoot.setAttribute("lang", preferredLang);
            }, function () { });
            let dirPromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getReadingDirection").then(function (dirVal) {
                _htmlRoot.setAttribute("dir", dirVal);
            }, function () { });
            let stringPromise = bridge.invoke("CloudExperienceHost.LocalAccount.localizedStringsSetupSQSA").then(function (result) {
                localAccountResources = JSON.parse(result);
            });
            let cssPromise = uiHelpers.LoadCssPromise(document.head, "..", bridge);
            return WinJS.Promise.join({ languagePromise, dirPromise, stringPromise, cssPromise });
        },
        ready: function (element, options) {
            let setContentFor = [UpdateSQSATitle, SQSALegend, FinishButton, CancelButton];
            for (let i = 0; i < setContentFor.length; i++) {
                setContentFor[i].textContent = localAccountResources[setContentFor[i].id];
            }
            let answerInputBoxes = [securityAnswer1, securityAnswer2, securityAnswer3];
            let answerPlaceholderValue = Array(3).fill('SecurityAnswerPlaceholder');
            for (let i = 0; i < answerInputBoxes.length; i++) {
                answerInputBoxes[i].setAttribute('placeholder', localAccountResources[answerPlaceholderValue[i]]);
            }
            let securityQuestionDropdown = [securityQuestion1, securityQuestion2, securityQuestion3];
            let questionPlaceholderValue = ['SecurityQuestion1Placeholder', 'SecurityQuestion2Placeholder', 'SecurityQuestion3Placeholder'];
            const NUM_SECURITY_QUESTIONS = 6;
            for (let i = 0; i < securityQuestionDropdown.length; i++) {
                let currDropdown = securityQuestionDropdown[i];
                currDropdown.options[0] = new Option(localAccountResources[questionPlaceholderValue[i]], '', true, true);
                answerInputBoxes[i].setAttribute('aria-label', localAccountResources[questionPlaceholderValue[i]]);
                currDropdown.setAttribute('aria-label', localAccountResources[questionPlaceholderValue[i]]);
                for (let j = 1; j <= NUM_SECURITY_QUESTIONS; j++) {
                    let question = localAccountResources['SecurityQuestion' + j];
                    currDropdown.options[j] = new Option(question, question);
                    currDropdown.options[j].title = question;
                }
            }
            FinishButton.addEventListener("click", function (event) {
                event.preventDefault();
                _onFinish.apply(this);
            }.bind(this));
            let checkAmersandFor = [FinishButton, CancelButton];
            checkAmersandFor.forEach(function (eachElement) {
                let result = CloudExperienceHost.ResourceManager.GetContentAndAccesskey(localAccountResources[eachElement.id]);
                eachElement.textContent = result.content;
                eachElement.accessKey = result.accessKey;
            });
            CancelButton.addEventListener("click", function (event) {
                event.preventDefault();
                _onCancel.apply(this);
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
                    let errorCode = validator.validateSecurityQuestionSelection(null, questionDropdown, questionNumber);
                    _checkErrorCodeAndShowError(this, errorCode);
                }.bind(this, currSecurityQuestionDropdown, i));
                currSecurityQuestionDropdown.addEventListener("change", function (securityErrorDialog, questionNumber) {
                    let errorCode = validator.validateSecurityQuestionSelection(null, this, questionNumber);
                    _checkErrorCodeAndHideError(this, errorCode, securityErrorDialog);
                }.bind(currSecurityQuestionDropdown, securityQuestionErrorDialog[i], i));
            }
            let securityAnswerInput = [securityAnswer1, securityAnswer2, securityAnswer3];
            let securityAnswerErrorDialog = [securityAnswer1_errorDialog, securityAnswer2_errorDialog, securityAnswer3_errorDialog];
            for (let i = 0; i < securityAnswerInput.length; i++) {
                let currSecurityAnswerInput = securityAnswerInput[i];
                currSecurityAnswerInput.addEventListener("blur", function (inputField, answerNumber) {
                    let errorCode = validator.validateSecurityAnswer(null, inputField, answerNumber);
                    _checkErrorCodeAndShowError(this, errorCode);
                }.bind(this, currSecurityAnswerInput, i));
                currSecurityAnswerInput.addEventListener("keyup", function (securityErrorDialog, answerNumber) {
                    let errorCode = validator.validateSecurityAnswer(null, this, answerNumber);
                    _checkErrorCodeAndHideError(this, errorCode, securityErrorDialog);
                }.bind(currSecurityAnswerInput, securityAnswerErrorDialog[i], i));
            }

            uiHelpers.RegisterEaseOfAccess(easeOfAccess, bridge);
            uiHelpers.RegisterInputSwitcher(inputSwitcher, bridge);

            bridge.fireEvent(CloudExperienceHost.Events.visible, true);

            bridge.invoke("CloudExperienceHost.LocalAccount.verifyLocalAccountCredentials").done(function (credsValidated) {
                if (!credsValidated) {
                    bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.abort);
                } else {
                    securityQuestion1.focus();
                }
            }, function (e) {
                bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.fail);
            });
            function _onFinish() {
                _setProgressState(true);
                let inputErrors = validator.validateSQSA(null, [securityQuestion1, securityQuestion2, securityQuestion3],
                    [securityAnswer1, securityAnswer2, securityAnswer3]);
                if (inputErrors.length === 0) {
                    let recoveryData = _serializeQuestions(); // unable to directly call serialize() on fieldset
                    bridge.invoke("CloudExperienceHost.LocalAccount.updateSQSA", recoveryData).done(function () {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "SQSAUpdateSucessful");
                        bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.success);
                    }, function (e) {
                        this._showError(this._getErrorCode(e.number), true /* setFocus */);
                        _setProgressState(false);
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "SQSAUpdateFailure", JSON.stringify({ errorNumber: e.number.toString(16), errorStack: e.asyncOpSource.stack }));
                    }.bind(this));
                }
                else {
                    _setProgressState(false);
                    for (let i = 0; i < inputErrors.length; i++) {
                        this._showError(inputErrors[i], (i === 0) /* setFocus */);
                    }
                }
            }
            function _onCancel() {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "UpdateSecurityQuestions_Cancelled");
                bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.cancel);
            }
            function _setProgressState(waiting) {
                FinishButton.disabled = waiting;
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
                case ErrorCodes.Error_Creating_Account_Warning:
                    resourceId = 'Error_Creating_Account_Warning';
                    inputField = securityAnswer3;
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

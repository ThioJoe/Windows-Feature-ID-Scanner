"use strict";

require.config(new RequirePathConfig('/webapps/hololensDiagnostics'));
define(['legacy/bridge', 'legacy/core', 'legacy/events'], (bridge, core, constants) => {
    const bookmarkPageIndicator = "hldiag_bookmark";
    const DiagPageEnum = {
        ErrorHandlerPage: 1,
        TroubleshootingPage: 2,
        SuccessPage: 3,
    };

    class HoloLensDiagnosticsViewModel {
        constructor(hololensDiagResources, bookmarkedPage) {
            this._logFileCollector = null;
            this._logFileCollector = new CloudExperienceHostAPI.Diagnostics.LogFileCollector();
            this._logFileCollector.registerLogFileSearchPattern("eventlog*system.etl*");
            this._logFileCollector.registerLogFileSearchPattern("eventlog*application.etl*");
            this._logFileCollector.registerLogFileSearchPattern("firstexperience*.etl*");

            this.hololensDiagResources = hololensDiagResources;
            this.bookmarkedPage = bookmarkedPage;

            var pageElementsWithTextContent = [Title, TroubleshootingLink, Body,
                PrivacyStatementLink, PrivacyHeadline, PrivacyBody,
                Instruction0, Instruction1, Instruction2, Instruction3, Instruction4,
                ProgressDescription];
            for (var i = 0; i < pageElementsWithTextContent.length; i++) {
                pageElementsWithTextContent[i].textContent = this.hololensDiagResources[pageElementsWithTextContent[i].id];
            }

            var buttonsWithContent = [RetryButton, CancelButton, ContinueButton, BackButton, NextButton];
            buttonsWithContent.forEach((eachElement) => {
                var resourceKey = this.hololensDiagResources[eachElement.id];
                var result = CloudExperienceHost.ResourceManager.GetContentAndAccesskey(resourceKey);
                eachElement.textContent = result.content;
                eachElement.accessKey = result.accessKey;
            });
        }

        registerEventHandlers() {
            TroubleshootingLink.addEventListener("click", ((event) => {
                event.preventDefault();
                this._onTroubleshooting.apply(this);
            }).bind(this), false);

            PrivacyStatementLink.addEventListener("click", this._showPrivacyFlyout, false);

            RetryButton.addEventListener("click", () =>  {
                RetryButton.disabled = true;
                WinJS.Application.restart();
            });

            CancelButton.addEventListener("click", ((event) => {
                event.preventDefault();
                CancelButton.disabled = true;
                bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
            }).bind(this));

            BackButton.addEventListener("click", ((event) => {
                event.preventDefault();
                BackButton.disabled = true;
                this._onBackButton.apply(this);
            }).bind(this));

            NextButton.addEventListener("click", ((event) => {
                event.preventDefault();
                NextButton.disabled = true;
                this._onNextButton.apply(this);
            }).bind(this));

            ContinueButton.addEventListener("click", ((event) => {
                event.preventDefault();
                ContinueButton.disabled = true;
                this._onContinueButton.apply(this);
            }).bind(this));
        }

        prepareFirstPage() {
            this._setVisibility(PageSpinner, false);
            this._setVisibility(BackButton, false);
            this._setVisibility(NextButton, false);
            this._setVisibility(PrivacyStatementLink, false);
            this._setVisibility(Instructions, false);

            switch (this.bookmarkedPage) {
                case DiagPageEnum.SuccessPage:
                    this._showSuccessPage();
                    break;
                case DiagPageEnum.TroubleshootingPage:
                    this._showOrHideTroubleshootingPage(true);
                    break;
                default:
                    this._showOrHideTroubleshootingPage(false);
                    break;
            }
        }

        _copyLogFiles() {
            var destinationPath = Windows.Storage.SystemDataPaths.getDefault().public;
            return this._logFileCollector.copyFilesAsync(destinationPath).then(() => {
                bridge.invoke("CloudExperienceHost.Storage.SharableData.addValue", bookmarkPageIndicator, DiagPageEnum.SuccessPage);
            });
        }

        _cleanupLogFiles() {
            return this._logFileCollector.deleteFilesAsync().then(() => {
                bridge.invoke("CloudExperienceHost.Storage.SharableData.removeValue", bookmarkPageIndicator);
            });
        }

        _onTroubleshooting() {
            this._showOrHideTroubleshootingPage(true);
        }

        _onBackButton() {
            if (this.bookmarkedPage === DiagPageEnum.TroubleshootingPage) {
                bridge.fireEvent(constants.Events.done, constants.AppResult.cancel);
            } else {
                this._showOrHideTroubleshootingPage(false);
            }
        }

        _onNextButton() {
            this._setVisibility(RetryButton, false);
            this._setVisibility(CancelButton, false);
            this._setVisibility(BackButton, false);
            this._setVisibility(NextButton, false);
            this._setVisibility(Title, false);
            this._setVisibility(PageBody, false);
            this._setVisibility(PageLogCollector, false);
            this._setVisibility(PageSpinner, true);

            this._copyLogFiles().done(() => {
                this._showSuccessPage();
            }, (e) => {
                this._reportErrorToTelemetry(e);
                this._showErrorPage();
            });
        }

        _onContinueButton() {
            this._cleanupLogFiles().done(() => {
                bridge.fireEvent(constants.Events.done, constants.AppResult.success);
            }, (e) => {
                this._reportErrorToTelemetry(e);
                bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
            });
        }

        _showOrHideTroubleshootingPage(showPage) {
            this._setVisibility(ContinueButton, false);

            this._setVisibility(RetryButton, !showPage);
            RetryButton.disabled = showPage;

            this._setVisibility(CancelButton, !showPage);
            CancelButton.disabled = showPage;

            this._setVisibility(TroubleshootingLink, !showPage);

            var titleKey = showPage ? 'TitleTroubleshooting' : 'Title';
            var bodyKey = showPage ? 'BodyTroubleshooting' : 'Body';
            Title.textContent = this.hololensDiagResources[titleKey];
            Body.textContent = this.hololensDiagResources[bodyKey];

            this._setVisibility(PrivacyStatementLink, showPage);

            this._setVisibility(BackButton, showPage);
            BackButton.disabled = !showPage;

            this._setVisibility(NextButton, showPage);
            NextButton.disabled = !showPage;

            if (!showPage) {
                RetryButton.focus();
            } else {
                NextButton.focus();
            }
        }

        _showSuccessPage() {

            Title.textContent = this.hololensDiagResources['TitleSuccess'];
            Body.textContent = this.hololensDiagResources['BodySuccess'];

            ContinueButton.focus();

            this._setVisibility(PageSpinner, false);
            this._setVisibility(TroubleshootingLink, false);
            this._setVisibility(PrivacyStatementLink, false);
            this._setVisibility(PageLogCollector, true);
            this._setVisibility(Title, true);
            this._setVisibility(PageBody, true);
            this._setVisibility(Instructions, true);
            this._setVisibility(RetryButton, false);
            this._setVisibility(CancelButton, false);
            this._setVisibility(ContinueButton, true);
        }

        _reportErrorToTelemetry(e) {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HoloLensDiagnosticsPageError", core.GetJsonFromError(e));
        }

        _showErrorPage() {

            Title.textContent = this.hololensDiagResources['TitleError'];
            Body.textContent = this.hololensDiagResources['BodyError'];

            CancelButton.disabled = false;
            CancelButton.focus();

            this._setVisibility(PageSpinner, false);
            this._setVisibility(TroubleshootingLink, false);
            this._setVisibility(PrivacyStatementLink, false);
            this._setVisibility(PageLogCollector, true);
            this._setVisibility(Title, true);
            this._setVisibility(PageBody, true);
            this._setVisibility(CancelButton, true);
        }

        _showPrivacyFlyout() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "HoloLensDiagnostics.ShowPrivacyFlyout");
            var flyoutButton = document.getElementById("PrivacyStatementLink");
            var flyout = document.getElementById("PrivacyFlyout");

            let rect = flyoutButton.getBoundingClientRect();
            flyout.style.marginTop = rect.bottom + (window.pageYOffset || document.documentElement.scrollTop || 0) + "px";

            flyout.winControl.show(flyoutButton, "top", "left");
        }

        _setVisibility(container, visible) {
            container.style.visibility = (visible) ? 'visible' : 'hidden';
            container.style.display = (visible) ? 'inline' : 'none';
        }
    }

    return HoloLensDiagnosticsViewModel;
});

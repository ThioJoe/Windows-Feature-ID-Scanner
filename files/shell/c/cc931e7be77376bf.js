define(['lib/knockout', 'legacy/appViewManager', 'legacy/navigationManager'], (ko, appViewManager, navManager) => {
    ko.bindingHandlers.addFooterWebView = {
        init: function (element, valueAccessor, allBindings, viewModel, bindingContext) {
            viewModel.attachFooterWebView(element);
        }
    };

    class SSPRFrameViewModel {
        constructor() {
            this.contentViewName = "oobe-chrome-contentview";

            this._webViewCtrl = document.createElement('x-ms-webview');
            this._webViewCtrl.className = "content-webview";
            this._webViewCtrl.setAttribute("aria-hidden", "true");

            CloudExperienceHost.Globalization.Utils.setDocumentElementLangAndDir();

            appViewManager.subscribe(this);
            appViewManager.subscribeForUpdateType(this, CloudExperienceHost.FrameViewModelUpdateType.Language);
            appViewManager.subscribeForUpdateType(this, CloudExperienceHost.FrameViewModelUpdateType.InputSwitchButton);
            appViewManager.subscribeForUpdateType(this, CloudExperienceHost.FrameViewModelUpdateType.ResetFooterFocus);
        }

        dispose() {
            appViewManager.unSubscrible();
            appViewManager.unsubscribeForUpdateType(this, CloudExperienceHost.FrameViewModelUpdateType.Language);
            appViewManager.unsubscribeForUpdateType(this, CloudExperienceHost.FrameViewModelUpdateType.InputSwitchButton);
            appViewManager.unsubscribeForUpdateType(this, CloudExperienceHost.FrameViewModelUpdateType.ResetFooterFocus);

            if (this._webViewCtrl) {
                WinJS.Utilities.empty(this._webViewCtrl);
            }

            let root = document.getElementById("_defaultRoot");
            if (root) {
                WinJS.Utilities.empty(root);
            }
        }

        setWebView(webViewCtrl) {
            this._webViewCtrl = webViewCtrl;
        }

        createWebView() {
            return this._webViewCtrl;
        }

        attachFooterWebView(parentElement) {
            if (!this._footerWebViewCtrl) {
                this._footerWebViewCtrl = document.createElement('x-ms-webview');
                this._footerWebViewCtrl.style.width = '100%';
                this._footerWebViewCtrl.style.height = '100%';
                this._footerWebViewCtrl.setAttribute("aria-hidden", "true");
                CloudExperienceHost.Discovery.getApiRules().done((rules) => {
                    let contractHandler = new CloudExperienceHost.ContractHandler(rules);
                    this._bridge = new CloudExperienceHost.Bridge(this._footerWebViewCtrl, contractHandler);
                    this._footerWebViewCtrl.navigate('ms-appx-web:///core/view/oobeFooterHost.html');
                    parentElement.appendChild(this._footerWebViewCtrl);
                });
            }
        }

        getView() {
            return document.getElementById('_view');
        }

        getContentViewBoundingRect() {
            return document.querySelector(".oobe-contentview").getBoundingClientRect();
        }

        getChromeFooterOffset() {
            if (this._footerWebViewCtrl) {
                let chromeFooterRect = this._footerWebViewCtrl.getBoundingClientRect();
                return { x: chromeFooterRect.left, y: chromeFooterRect.top };
            } else {
                return { x: 0, y: 0 };
            }
        }

        update(updateType, completeDispatch, errorDispatch, updateTag) {
            let progressControl = document.getElementById("_progress");
            let progressText = document.getElementById("_progressText");
            let progressElement = document.getElementsByTagName("oobe-progress")[0];
            let view = this.getView();

            switch (updateType) {
                case CloudExperienceHost.FrameViewModelUpdateType.Progress:
                    const displayStyle = "flex";
                    AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Speech.SpeechSynthesis").stop();
                    AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Speech.SpeechRecognition").stop();

                    document.querySelector(".app-content").classList.remove("dimmed");
                    progressElement.removeAttribute("aria-hidden");
                    progressControl.removeAttribute("aria-hidden");
                    progressText.removeAttribute("aria-hidden");

                    progressElement.style.display = displayStyle;

                    navManager.setDisableBackNavigation(true);

                    WinJS.UI.Animation.crossFade(progressElement, view).done(() => {
                        progressElement.style.display = displayStyle;
                        progressText.focus();

                        if (!this._progressTextTimerID) {
                            this._progressTextTimerID = setTimeout(function () {
                                progressText.textContent = progressText.textContent;
                            }, 3000);
                        }

                        if (!this._progressTextIntervalID) {
                            this._progressTextIntervalID = setInterval(function () {
                                progressText.textContent = progressText.textContent;
                            }, 30000);
                        }

                        completeDispatch();
                    }, errorDispatch);
                    break;
                case CloudExperienceHost.FrameViewModelUpdateType.View:
                    document.querySelector(".app-content").classList.remove("dimmed");
                    progressElement.setAttribute("aria-hidden", "true");
                    progressControl.setAttribute("aria-hidden", "true");
                    progressText.setAttribute("aria-hidden", "true");

                    if (this._webViewCtrl) {
                        this._webViewCtrl.focus();
                    }

                    if (this._progressTextTimerID) {
                        clearTimeout(this._progressTextTimerID);
                        this._progressTextTimerID = null;
                    }

                    if (this._progressTextIntervalID) {
                        clearInterval(this._progressTextIntervalID);
                        this._progressTextIntervalID = null;
                    }

                    WinJS.UI.Animation.crossFade(view, progressElement).done(() => {
                        progressElement.style.display = "none"; // hide the progress element completely
                        completeDispatch();
                    }, errorDispatch);
                    break;
                case CloudExperienceHost.FrameViewModelUpdateType.Language:
                    if (this._bridge) {
                        this._bridge.fireEvent(CloudExperienceHost.Events.languageChange, updateTag);
                    }
                    CloudExperienceHost.Globalization.Utils.setDocumentElementLangAndDir();
                    completeDispatch();
                    break;
                case CloudExperienceHost.FrameViewModelUpdateType.ResetFooterFocus:
                    if (this._bridge) {
                        this._bridge.fireEvent(CloudExperienceHost.Events.resetFooterFocus);
                    }
                    completeDispatch();
                    break;
                case CloudExperienceHost.FrameViewModelUpdateType.InputSwitchButton:
                    if (this._bridge) {
                        this._bridge.fireEvent(CloudExperienceHost.Events.inputSwitchIndicatorChange);
                    }
                    completeDispatch();
                    break;
                case CloudExperienceHost.FrameViewModelUpdateType.Dimmed:
                    document.querySelector(".app-content").classList.add("dimmed");

                    if (this._progressTextTimerID) {
                        clearTimeout(this._progressTextTimerID);
                        this._progressTextTimerID = null;
                    }

                    if (this._progressTextIntervalID) {
                        clearInterval(this._progressTextIntervalID);
                        this._progressTextIntervalID = null;
                    }
                    progressText.blur();
                    completeDispatch();
                    break;
                case CloudExperienceHost.FrameViewModelUpdateType.Undimmed:
                    document.querySelector(".app-content").classList.remove("dimmed");
                    completeDispatch();
                    break;
            }
        }
    }
    return SSPRFrameViewModel;
});

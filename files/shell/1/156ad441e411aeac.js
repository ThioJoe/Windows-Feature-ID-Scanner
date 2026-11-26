
define(['lib/knockout'], (ko) => {
    class NavigationManager {
        constructor() {
            this.listeners = new Object;
            this.navigator = null;
            this.bridge = null;
            this.webviewCtrl = null;
            this.appView = null;
            this.observers = {};

            this.canNavigateToPreviousWebapp = ko.observable(false);
            this.canNavigateToPreviousPanel = ko.observable(false);
            this.shouldDisableBackNavigation = ko.observable(false);
            this.canNavigateToCurrentWebapp = ko.observable(false);
            this.canExitCxhFromCurrentWebapp = ko.observable(false);

            this.canNavigateToPreviousWebapp.subscribe((newvalue) => {
                this.evaluateBackNavigationAndNotify();
            });

            this.canNavigateToPreviousPanel.subscribe((newvalue) => {
                this.evaluateBackNavigationAndNotify();
            });

            this.shouldDisableBackNavigation.subscribe((newvalue) => {
                this.evaluateBackNavigationAndNotify();
            });

            this.canNavigateToCurrentWebapp.subscribe((newvalue) => {
                this.evaluateBackNavigationAndNotify();
            });

            this.canExitCxhFromCurrentWebapp.subscribe((newvalue) => {
                this.evaluateExitCxhAndNotify();
            });

            AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.AppEventSubscriptionManager").addEventListener("back", this.navigateBack.bind(this));

            if (CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("WindowsAutopilotDiagnostics")) {
                AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.AppEventSubscriptionManager").addEventListener("diagnostics", this.navigateToDiagnostics.bind(this));
            }
        }

        registerNavigator(navigatorInstance)
        {
            this.navigator = navigatorInstance;
        }

        registerBridge(bridgeInstance)
        {
            this.bridge = bridgeInstance;
        }

        registerWebviewCtrl(viewinstance)
        {
            this.webviewCtrl = viewinstance;
        }

        registerAppView(appViewInstance)
        {
            this.appView = appViewInstance;
        }

        navigateBack() {
            if (this.canNavigateToPreviousPanel()) {
                this.bridge.fireEvent(CloudExperienceHost.Events.backButtonClicked, null);
                document.activeElement.blur();
                this.webviewCtrl.focus();
            }
            else if (this.canNavigateToPreviousWebapp() || this.canNavigateToCurrentWebapp()) {
                if (this.appView) {
                    this.appView.showProgress().then(function () {
                        this.navigator.goToPreviousVisitedNode();
                    }.bind(this));
                }
                else {
                    this.navigator.goToPreviousVisitedNode();
                }
            }
        }

        navigateToDiagnostics() {
            if (this.navigator != null) {
                let diagnosticsNode = this.navigator.getDiagnosticsNode();
                let currentNode = this.navigator.getCurrentNode();

                if ((diagnosticsNode != null) && (diagnosticsNode.cxid != "") && (diagnosticsNode != currentNode)) {
                    CloudExperienceHost.Storage.SharableData.addValue("DiagnosticsPreviousCXID", currentNode.cxid);

                    if (this.appView) {
                        this.appView.showProgress().then(function () {
                            this.navigator.navigateToNode(diagnosticsNode);
                        }.bind(this));
                    }
                    else {
                        this.navigator.navigateToNode(diagnosticsNode);
                    }
                }
            }
        }

        closeCxh() {
            if (this.canExitCxhFromCurrentWebapp()) {
                CloudExperienceHost.cancel();
            }
        }

        evaluateBackNavigationAndNotify() {
            if (!this.shouldDisableBackNavigation() && (this.canNavigateToPreviousWebapp() || this.canNavigateToPreviousPanel() || this.canNavigateToCurrentWebapp())) {
                this.fireEvent("ShowBackButton");
                AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.AppEventNotificationManager").notifyBackStateChanged(true);
            }
            else {
                this.fireEvent("HideBackButton");
                AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.AppEventNotificationManager").notifyBackStateChanged(false);
            }
        }

        evaluateExitCxhAndNotify() {
            if (this.canExitCxhFromCurrentWebapp()) {
                this.fireEvent("ShowCloseButton");
            } else {
                this.fireEvent("HideCloseButton");
            }
        }

        setExitCxhAvailability(isAvailable) {
            this.canExitCxhFromCurrentWebapp(isAvailable);
        }

        setWebAppBackNavigationAvailability(isAvailable)
        {
            this.canNavigateToPreviousPanel(false);
            this.canNavigateToCurrentWebapp(false);
            this.canNavigateToPreviousWebapp(isAvailable);
        }

        setPanelBackNavigationAvailability(isAvailable) {
            this.canNavigateToPreviousPanel(isAvailable);
        }

        setDisableBackNavigation(disableBackNavigation) {
            let value = (typeof disableBackNavigation !== 'undefined') && disableBackNavigation;
            this.shouldDisableBackNavigation(value);
        }

        setBackNavigationCheckpoint() {
            if (this.navigator.addCurrentNodeToTopOfBackstack()) {
                this.shouldDisableBackNavigation(false);
                this.setPanelBackNavigationAvailability(false);
                this.canNavigateToCurrentWebapp(true);
            }
        }

        fireEvent(eventName, e) {
            var listeners = this.listeners[eventName];
            if (listeners) {
                for (let listener of listeners) {
                    listener.call(this, e);
                }
            }
        }

        addEventListener(type, listener) {
            if (!this.listeners.hasOwnProperty(type)) {
                this.listeners[type] = new Array();
            }
            this.listeners[type].push(listener);
        }

        addNavigationEventListener(type, listener) {
            this.navigator.addEventListener(type, listener);
        }

        getFailedNode() {
            return this.navigator.getResumeNode();
        }

        notifyEvent(event, payload) {
            if (this.observers[event]) {
                for (let observer of this.observers[event]) {
                    observer.onNavigationEvent(event, payload);
                }
            }
        }

        subscribeForNavigationEvent(observer, event) {
            if (!this.observers[event]) {
                this.observers[event] = [];
                this.observers[event].push(observer);
            }
            else if (this.observers[event].indexOf(observer) == -1) {
                this.observers[event].push(observer);
            }
        }

        unsubscribeForNavigationEvent(observer, event) {
            if (this.observers[event]) {
                let obsIndex = this.observers[event].indexOf(observer);
                if (obsIndex != -1) {
                    this.observers[event].splice(obsIndex, 1);
                }
            }
        }
    }

    return new NavigationManager();
});

"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    class XboxTcuiContext {
        constructor(context) {
            this._context = context;
        }
        reportCompleted(valueSet) {
            this._context.asyncOperation.complete(valueSet);
        }
    }
    CloudExperienceHost.XboxTcuiContext = XboxTcuiContext;
})(CloudExperienceHost || (CloudExperienceHost = {}));

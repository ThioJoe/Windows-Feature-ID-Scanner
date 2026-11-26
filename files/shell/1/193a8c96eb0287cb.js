//
// Copyright (C) Microsoft. All rights reserved.
//
// Avoid conflict with Common.Proxy vs browser's Proxy
const ES6Proxy = window.Proxy;
var Common;
(function (Common) {
    "use strict";
    function getStringProxy(moduleName) {
        const moduleId = moduleName.replace(/\//g, "_") + "_";
        return new ES6Proxy({}, {
            get(target, stringIndex) {
                const stringId = moduleId + stringIndex;
                try {
                    return Microsoft.Plugin.Resources.getString(stringId);
                }
                catch (e) {
                    return isDebugBuild ? "MISSING STRING " + stringId : "";
                }
            }
        });
    }
    // define is in loader.js, which only exists in tools using Monaco
    if (typeof define !== "undefined") {
        const moduleProxy = new ES6Proxy({}, {
            get(target, moduleName) {
                return getStringProxy(moduleName);
            }
        });
        define("vs/base/common/worker/workerServer.nls", moduleProxy);
        define("vs/languages/html/common/htmlWorker.nls", moduleProxy);
        define("vs/base/common/worker/simpleWorker.nls", moduleProxy);
        define("vs/editor/editor.main.nls", moduleProxy);
    }
})(Common || (Common = {}));
//# sourceMappingURL=f12Nls.js.map
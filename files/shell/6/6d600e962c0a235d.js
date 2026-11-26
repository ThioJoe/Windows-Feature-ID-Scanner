//    Copyright (C) Microsoft.  All rights reserved.

// This is for handling modules that were not found. Instead you load a "fake" module and request 
// requirejs to continue loading the other modules.
define("optional", [], {
    load : function (moduleName, parentRequire, onload, config){

        var onLoadSuccess = function(moduleInstance){
            // Module successfully loaded, call the onload callback so that
            // requirejs can work its internal magic.
            onload(moduleInstance);
        }

        var onLoadFailure = function(err){
            // optional module failed to load.
            var failedId = err.requireModules && err.requireModules[0];

            // Undefine the module to cleanup internal stuff in requireJS
            requirejs.undef(failedId);

            // Now define the module instance as something that is not an object
            // We use this property to distinguish from a real object
            define(failedId, [], function(){return "";});

            // Now require the module to make sure that requireJS thinks 
            // that it is loaded. Since we've just defined it, requirejs 
            // will not attempt to download any more script files and
            // will just call the onLoadSuccess handler immediately
            parentRequire([failedId], onLoadSuccess);
        }

        parentRequire([moduleName], onLoadSuccess, onLoadFailure);
    }
});
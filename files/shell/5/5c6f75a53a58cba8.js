//
// Copyright (C) Microsoft. All rights reserved.
//

var _anim;
var _previousAnimationFile;

function isValidHttpsUrl(string) {
    let url;
    try {
        url = new URL(string);
    } catch (e) {
        // No need to log error here in order to decrease unnecessary noise
        return false;
    }
    return url.protocol === "https:";
}

function isValidAppDataUrl(string) {
    let url;
    try {
        url = new URL(string);
    } catch (e) {
        // No need to log error here in order to decrease unnecessary noise
        return false;
    }
    return url.protocol === 'ms-appdata:';
}

function isValidLottieObject(obj) {
    return (
        obj &&
        typeof obj === "object" &&
        typeof obj.v === "string" &&
        typeof obj.fr === "number" &&
        typeof obj.ip === "number" &&
        typeof obj.op === "number" &&
        typeof obj.ddd === "number" &&
        Array.isArray(obj.layers) &&
        Array.isArray(obj.assets)
    );
}

function updateAnimObj(lottieStr) {
    lottieObj = JSON.parse(lottieStr);
    if (_previousAnimationFile !== lottieStr) {
        _previousAnimationFile = lottieStr;
        if (_anim) {
            exitAnim();
        }
        setTimeout(() => {
            clearAnimation();
            if (lottieObj && isValidLottieObject(lottieObj)) {
                let animationContainer = document.getElementById("animation");
                _anim = loadAnimsWithObj(animationContainer, lottieObj);
            }
        }, 500);
    }
}

function updateAnim(fileName) {
    if (_previousAnimationFile !== fileName)
    {
        _previousAnimationFile = fileName;
        if (_anim) {
            exitAnim();
        }
    
        setTimeout(() => {
            clearAnimation();
            if (fileName) {
                let animationContainer = document.getElementById("animation");
                _anim = loadAnims(animationContainer, fileName);
            }
        }, 500);
    }
}

// Function to load all bodymovin animations and assign event listeners to each
function loadAnims(animationContainer, fileName) {
    let element = animationContainer,
        thisAnim = null,
        file = fileName,
        name = file.replace(/$.json/, ""),
        path = (isValidHttpsUrl(fileName) || isValidAppDataUrl(fileName)) ? fileName : ("../media/" + file),
        assetsPath = (isValidHttpsUrl(fileName) || isValidAppDataUrl(fileName)) ? "ms-appdata:///temp/" : "../media/",
        params = {
            assetsPath: assetsPath,
            container: element,
            renderer: "svg",
            name: name,
            loop: false,
            autoplay: false,
            path: path
        };

    thisAnim = bodymovin.loadAnimation(params);

    // Add events to this animation
    thisAnim.addEventListener('DOMLoaded', () => {
        parent = element.parentNode;
        enterAnim(false);
    });

    return thisAnim;
}

function loadAnimsWithObj(animationContainer, lottieObj) {
    let thisAnim = null,
        params = {
            container: animationContainer,
            renderer: "svg",
            loop: false,
            autoplay: false,
            animationData: lottieObj,
        };

    thisAnim = bodymovin.loadAnimation(params);

    thisAnim.addEventListener('DOMLoaded', () => {
        parent = animationContainer.parentNode;
        enterAnim(false);
    });

    return thisAnim;
}

function enterAnim(loop) {
    if (_anim.isPaused) {
        _anim.loop = loop;
        _anim.playSegments([0, 120], true);
    }
}

function exitAnim() {
    if (_anim.isPaused) {
        _anim.loop = false;
        _anim.playSegments([180, 210], false);
    }
}

function clearAnimation() {
    if (_anim) {
        bodymovin.destroy(_anim.name);
        _anim = null;
    }
}

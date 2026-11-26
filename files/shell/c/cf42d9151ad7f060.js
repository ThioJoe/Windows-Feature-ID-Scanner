const dataUri = document.getElementById("local-area-content").src;

// this would work in a world where we weren't using Axios, and 
// fetch(dataUri)
//     .then((data) => data.json())
//     .then((data) => {
//         root.setAttribute("data-compass", JSON.stringify(data)) ;
//     });

// we didn't need to support IE11, but instead, let's figure 
// out a way to do this very old school...
// Note, in order for this to work, the caller must 
// have already made Axios available, as well as polyfilled
// for Promises (use Bluebird), which IE11 won't have.

let options = {
  method: "GET",
  url: dataUri,
  headers: {
      "Accept": "application/json",
      "Content-Type": "application/json;charset=UTF-8"
  }
}

/**
 * Set area content into the app root div when React app run without Webrole.
 */
function setAttrs(response) {
  const root = document.getElementById("root");
  root.setAttribute("data-area-content", JSON.stringify(response.data));
}

// Called from reactJS app to load the content and then render reactJS DOM
function loadAreaContent(lang) {
  if (lang && !(lang === "")) {
    let index = options.url.lastIndexOf("/");
    options.url = options.url.substr(0, index) + "/" + lang + options.url.substr(index);
  }
  return new Promise(resolve => {
    axios(options).then(response => {
      setAttrs(response);
      resolve();
    });
  });
}

// wpgsa.js v0.1.0
// script for wpgsa.org
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // replace atag text to button
  replaceTextToButton("Download TF binding peak data")
  replaceTextToButton("Donwload data list (.xlsx)")
});

// functions

// For button decorations
function searchAlink(searchText){
  var aTags = document.getElementsByTagName("a");
  var found;
  for (var i = 0; i < aTags.length; i++) {
    if (aTags[i].textContent.includes(searchText)) {
      found = aTags[i];
      break;
    }
  }
  return found;
}

function replaceTextToButton(searchText){
  var aTag = $(searchAlink(searchText));
  aTag.attr("class", "btn btn-default downloadLink");
}

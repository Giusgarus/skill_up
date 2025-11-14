/* eslint-env serviceworker */
importScripts('https://www.gstatic.com/firebasejs/9.23.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/9.23.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyBstGeXmdjBW5dAM9UhPS2atVY0UuIU6dI',
  authDomain: 'skillup-da594.firebaseapp.com',
  projectId: 'skillup-da594',
  storageBucket: 'skillup-da594.firebasestorage.app',
  messagingSenderId: '509458332950',
  appId: '1:509458332950:web:b646d9d63ebaa7cfa22437',
  measurementId: 'G-B7L0YYWECK',
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  const title = payload.notification?.title ?? 'SkillUp';
  const body = payload.notification?.body ?? '';
  const notificationOptions = {
    body,
    icon: '/icons/Icon-192.png',
    data: payload.data ?? {},
  };
  self.registration.showNotification(title, notificationOptions);
});

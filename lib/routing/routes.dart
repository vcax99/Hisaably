/// Route paths. Member (and Group Admin) screens live under /m, Super Admin
/// screens under /a. Group Admin uses the member shell; group management is
/// reached from the Groups tab.
abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const settings = '/settings';

  static const memberPrefix = '/m/';
  static const adminPrefix = '/a/';

  static const memberDashboard = '/m/dashboard';
  static const memberExpenses = '/m/expenses';
  static const memberIncome = '/m/income';
  static const memberGroups = '/m/groups';

  static const adminDashboard = '/a/dashboard';
  static const adminGroups = '/a/groups';
  static const adminUsers = '/a/users';
  static const adminMore = '/a/more';
  static const adminNewUser = '/a/users/new';
  static String adminUser(String id) => '/a/users/$id';
  static String adminGroup(String id) => '/a/groups/$id';

  static const notifications = '/notifications';

  static const addTransactionPattern = '/transactions/new/:type';
  static String addTransaction(String type) => '/transactions/new/$type';
}

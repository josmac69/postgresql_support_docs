CREATE DATABASE IF NOT EXISTS sourcedb;
USE sourcedb;

CREATE TABLE IF NOT EXISTS departments (
    dept_id INT PRIMARY KEY,
    dept_name VARCHAR(50) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS employees (
    emp_id INT PRIMARY KEY,
    emp_name VARCHAR(100) NOT NULL,
    hire_date DATE NOT NULL,
    salary DECIMAL(10,2) NOT NULL,
    dept_id INT,
    FOREIGN KEY (dept_id) REFERENCES departments(dept_id)
) ENGINE=InnoDB;

-- Insert sample data
INSERT INTO departments (dept_id, dept_name) VALUES
(10, 'Engineering'),
(20, 'Product'),
(30, 'Operations')
ON DUPLICATE KEY UPDATE dept_name=VALUES(dept_name);

INSERT INTO employees (emp_id, emp_name, hire_date, salary, dept_id) VALUES
(101, 'Alice Smith', '2020-03-15', 95000.00, 10),
(102, 'Bob Jones', '2021-06-01', 82000.00, 10),
(103, 'Charlie Brown', '2022-01-10', 75000.00, 20),
(104, 'Diana Prince', '2019-11-20', 105000.00, 30)
ON DUPLICATE KEY UPDATE 
    emp_name=VALUES(emp_name), 
    hire_date=VALUES(hire_date), 
    salary=VALUES(salary), 
    dept_id=VALUES(dept_id);
